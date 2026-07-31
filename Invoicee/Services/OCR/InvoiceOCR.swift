import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(VisionKit)
internal import SwiftUI
import VisionKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum InvoiceOCRError: LocalizedError {
    case unavailable
    case invalidImage
    case recognitionFailed
    case scanCancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: "Invoice OCR is not available on this device."
        case .invalidImage: "The scanned image could not be processed."
        case .recognitionFailed: "Unable to extract text from the invoice."
        case .scanCancelled: nil // Cancelling is not an error worth showing.
        }
    }
}

/// Extracts supplier, date, totals, and line items from a photographed invoice.
///
/// Declared `nonisolated` so the Vision pass runs off the main actor. The project
/// defaults to `MainActor` isolation, which previously meant a multi-second text
/// recognition on a full-resolution scan blocked the UI while the "Extracting invoice
/// details…" spinner was supposed to be animating.
nonisolated enum InvoiceOCRProcessor {
#if canImport(Vision) && canImport(UIKit)
    /// Vertical distance, in normalised image coordinates, within which two text blocks
    /// are treated as being on the same line.
    private enum Layout {
        static let sameRow: CGFloat = 0.02
        static let sameRowForTotals: CGFloat = 0.025
        /// Item names sit a little further off their price than a label does.
        static let sameRowForItemNames: CGFloat = 0.04
        /// How far left of a label a value may start and still be considered its value.
        static let valueOverhang: CGFloat = 0.02
    }

    static func process(image: UIImage, knownSuppliers: [String] = []) async throws -> ManualInvoiceData {
        guard let cgImage = image.cgImage else {
            throw InvoiceOCRError.invalidImage
        }
        return try recognize(cgImage: cgImage, knownSuppliers: knownSuppliers)
    }

    private static func recognize(cgImage: CGImage, knownSuppliers: [String]) throws -> ManualInvoiceData {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3

        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw InvoiceOCRError.recognitionFailed
        }

        let entries = observations.compactMap(RecognizedEntry.init(observation:))
        guard !entries.isEmpty else { throw InvoiceOCRError.recognitionFailed }

        var data = ManualInvoiceData()
        let lines = entries.map(\.text)
        data.supplier = matchSupplier(in: lines, knownSuppliers: knownSuppliers) ?? lines[0]

        if let detectedDate = findDate(in: lines) {
            data.date = detectedDate
        }

        var usedPriceIDs: Set<UUID> = []

        if let total = findTotalAmount(in: entries) {
            data.totalAmount = total.amount
            usedPriceIDs.insert(total.priceEntryID)
        }

        let itemExtraction = extractLineItems(from: entries, excludingPriceIDs: usedPriceIDs)
        data.items = itemExtraction.items
        usedPriceIDs.formUnion(itemExtraction.usedPriceIDs)

        if let gst = findGSTAmount(in: entries, usedPriceIDs: usedPriceIDs) {
            data.gstAmount = gst.amount
            usedPriceIDs.insert(gst.priceEntryID)
        }

        if data.totalAmount == nil {
            data.totalAmount = fallbackTotal(from: entries, excludingPriceIDs: usedPriceIDs)
        }

        data.ourAmount = data.totalAmount
        data.hasCustomOurAmount = false
        data.gstAmount = GSTValidator.sanitizedAmount(for: data.gstAmount, total: data.totalAmount)
        data.items = itemsExcludingTotalRow(data.items, total: data.totalAmount)
        return data
    }

    // MARK: - Field detection

    private static func findDate(in lines: [String]) -> Date? {
        for line in lines {
            for pattern in datePatterns {
                if let dateString = pattern.firstMatchText(in: line),
                   let parsed = parseDate(from: dateString) {
                    return parsed
                }
            }
        }
        return nil
    }

    /// Finds the invoice total by looking for a price to the right of a "total"-ish label.
    ///
    /// When several labels match, the one highest up the page wins: an invoice's grand
    /// total sits above any payment or remittance restatement of it.
    private static func findTotalAmount(in entries: [RecognizedEntry]) -> (amount: Decimal, priceEntryID: UUID)? {
        let labels = entries.filter { entry in
            let lower = entry.text.lowercased()
            return lower.contains("total") || lower.contains("amount due") || lower.contains("balance")
        }

        let prices = entries.filter { currencyRegex.matches($0.text) }
        var best: (amount: Decimal, priceEntryID: UUID, y: CGFloat)?

        for label in labels {
            guard let price = nearestValue(to: label, among: prices, rowTolerance: Layout.sameRowForTotals),
                  let amount = amount(in: price.text) else { continue }

            if best == nil || price.boundingBox.minY < best!.y {
                best = (amount, price.id, price.boundingBox.minY)
            }
        }

        return best.map { ($0.amount, $0.priceEntryID) }
    }

    private static func findGSTAmount(in entries: [RecognizedEntry],
                                      usedPriceIDs: Set<UUID>) -> (amount: Decimal, priceEntryID: UUID)? {
        let labels = entries.filter { entry in
            let lower = entry.text.lowercased()
            return lower.contains("gst") || lower.contains("tax")
        }
        guard !labels.isEmpty else { return nil }

        let prices = entries.filter { !usedPriceIDs.contains($0.id) && currencyRegex.matches($0.text) }

        for label in labels {
            if let price = nearestValue(to: label, among: prices, rowTolerance: Layout.sameRow),
               let amount = amount(in: price.text) {
                return (amount, price.id)
            }
        }
        return nil
    }

    /// The topmost unclaimed price on the page, used when no total label was found.
    private static func fallbackTotal(from entries: [RecognizedEntry],
                                      excludingPriceIDs: Set<UUID>) -> Decimal? {
        entries
            .lazy
            .filter { !excludingPriceIDs.contains($0.id) && currencyRegex.matches($0.text) }
            .sorted { $0.boundingBox.minY < $1.boundingBox.minY }
            .compactMap { amount(in: $0.text) }
            .first
    }

    /// Pairs each remaining `$`-prefixed price with the nearest descriptive text to its
    /// left, treating that pair as a line item.
    private static func extractLineItems(from entries: [RecognizedEntry],
                                         excludingPriceIDs: Set<UUID>) -> (items: [ManualInvoiceItem], usedPriceIDs: Set<UUID>) {
        var usedPriceIDs = excludingPriceIDs
        var items: [ManualInvoiceItem] = []

        // Requiring "$" keeps quantities and reference numbers out of the item list.
        let priceEntries = entries
            .filter { !usedPriceIDs.contains($0.id) && $0.text.contains("$") && currencyRegex.matches($0.text) }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        for priceEntry in priceEntries {
            guard let amountText = currencyRegex.firstMatchText(in: priceEntry.text) else { continue }

            let sameRow = entries.filter {
                abs($0.boundingBox.midY - priceEntry.boundingBox.midY) < Layout.sameRowForItemNames
            }

            let nameCandidates = sameRow
                .filter { $0.boundingBox.midX < priceEntry.boundingBox.midX && $0.isPlausibleItemName }
                .sorted { lhs, rhs in
                    let lhsDrop = abs(lhs.boundingBox.midY - priceEntry.boundingBox.midY)
                    let rhsDrop = abs(rhs.boundingBox.midY - priceEntry.boundingBox.midY)
                    // Same row: prefer the label closest to the price.
                    return lhsDrop == rhsDrop ? lhs.boundingBox.maxX > rhs.boundingBox.maxX : lhsDrop < rhsDrop
                }

            guard let nameEntry = nameCandidates.first else { continue }

            var item = ManualInvoiceItem()
            item.name = nameEntry.text
            item.totalAmount = amountText.replacingOccurrences(of: " ", with: "")
            item.unitPrice = sameRow
                .first { $0.boundingBox.midX >= nameEntry.boundingBox.minX && unitPriceRegex.matches($0.text.lowercased()) }?
                .text ?? ""

            items.append(item)
            usedPriceIDs.insert(priceEntry.id)
        }

        return (items, usedPriceIDs)
    }

    /// The value belonging to `label`: the entry on the same row that starts at or after
    /// the label's midpoint, closest vertically.
    private static func nearestValue(to label: RecognizedEntry,
                                     among candidates: [RecognizedEntry],
                                     rowTolerance: CGFloat) -> RecognizedEntry? {
        candidates
            .filter { candidate in
                abs(candidate.boundingBox.midY - label.boundingBox.midY) < rowTolerance
                    && candidate.boundingBox.minX > label.boundingBox.midX - Layout.valueOverhang
            }
            .min { lhs, rhs in
                abs(lhs.boundingBox.midY - label.boundingBox.midY) < abs(rhs.boundingBox.midY - label.boundingBox.midY)
            }
    }

    /// Drops any item whose amount equals the invoice total — that row is the total
    /// itself, matched as an item because it happened to sit beside a description.
    private static func itemsExcludingTotalRow(_ items: [ManualInvoiceItem], total: Decimal?) -> [ManualInvoiceItem] {
        guard let total, items.count > 1 else { return items }
        return items.filter { amount(in: $0.totalAmount) != total }
    }

    private static func matchSupplier(in lines: [String], knownSuppliers: [String]) -> String? {
        let candidates = knownSuppliers.compactMap { supplier -> (original: String, normalized: String)? in
            guard let normalized = supplier.trimmed.lowercased().nilIfEmpty else { return nil }
            return (supplier, normalized)
        }
        guard !candidates.isEmpty else { return nil }

        let normalizedLines = lines.compactMap { $0.trimmed.lowercased().nilIfEmpty }

        // An exact line match is a much stronger signal than an incidental substring, so
        // check every line for one before falling back to a scan of the whole document.
        for line in normalizedLines {
            if let exact = candidates.first(where: { line == $0.normalized }) {
                return exact.original
            }
        }

        let combined = normalizedLines.joined(separator: " ")
        return candidates.first { combined.contains($0.normalized) }?.original
    }

    // MARK: - Parsing

    /// The numeric value inside a currency fragment such as "$1,234.50".
    private static func amount(in text: String) -> Decimal? {
        guard let matched = currencyRegex.firstMatchText(in: text) else { return nil }
        return Decimal(string: matched
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: ""))
    }

    private static func parseDate(from string: String) -> Date? {
        guard let groups = dateComponentsRegex.firstMatchGroups(in: string), groups.count == 3 else {
            return nil
        }

        var year = groups[2]
        if year.count == 2 {
            year = "20" + year
        }
        let day = groups[0].count == 1 ? "0" + groups[0] : groups[0]
        let month = groups[1].count == 1 ? "0" + groups[1] : groups[1]

        return ReportingDateFormatter.parseInvoiceDay("\(day)-\(month)-\(year)")
    }

    private static let datePatterns: [NSRegularExpression] = [
        .compiled(#"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#),
        .compiled(#"\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b"#)
    ]

    private static let dateComponentsRegex: NSRegularExpression = .compiled(#"(\d{1,2})\D+(\d{1,2})\D+(\d{2,4})"#)
    private static let currencyRegex: NSRegularExpression = .compiled(#"\$?\s*(\d{1,3}(,\d{3})*|\d+)(\.\d{2})?"#)
    private static let unitPriceRegex: NSRegularExpression = .compiled(#"\b\d+(?:\.\d+)?\s*/\s*(ea|kg|g|lb|ml|l|pack|pc)s?\b"#)
#else
    static func process(image: Any, knownSuppliers: [String] = []) async throws -> ManualInvoiceData {
        throw InvoiceOCRError.unavailable
    }
#endif
}

#if canImport(Vision)
/// One block of recognised text and where it sits on the page, in normalised
/// bottom-left-origin coordinates.
///
/// `nonisolated` so its initialiser can be used as a function value (`compactMap(init)`)
/// and its members read from the off-main-actor recognition pass.
private nonisolated struct RecognizedEntry: Identifiable {
    let id = UUID()
    let text: String
    let boundingBox: CGRect

    init?(observation: VNRecognizedTextObservation) {
        guard let candidate = observation.topCandidates(1).first,
              let trimmed = candidate.string.trimmed.nilIfEmpty else { return nil }
        text = trimmed
        boundingBox = observation.boundingBox
    }

    /// Text that could name a line item: not a price, not a unit rate, and not one of
    /// the summary labels whose neighbouring amount is a total rather than an item.
    var isPlausibleItemName: Bool {
        guard !text.contains("$") else { return false }
        let lower = text.lowercased()
        let summaryLabels = ["total", "subtotal", "tax", "gst", "balance", "amount due"]
        return !summaryLabels.contains { lower.contains($0) }
    }
}
#endif

/// `nonisolated` so the OCR pass, which runs off the main actor, can use these.
nonisolated extension NSRegularExpression {
    /// A regex from a literal pattern known at compile time.
    ///
    /// Traps on a malformed pattern, which can only be a programming error: these are
    /// all string literals in this file. Previously some call sites built their regex
    /// with `try?` inside the matching loop, silently matching nothing on a typo and
    /// recompiling the pattern for every line of every scan.
    static func compiled(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid regular expression literal '\(pattern)': \(error)")
        }
    }

    private func fullRange(of string: String) -> NSRange {
        NSRange(location: 0, length: string.utf16.count)
    }

    func matches(_ string: String) -> Bool {
        firstMatch(in: string, options: [], range: fullRange(of: string)) != nil
    }

    /// The text of the first match, or `nil` when the pattern does not match.
    func firstMatchText(in string: String) -> String? {
        guard let match = firstMatch(in: string, options: [], range: fullRange(of: string)),
              let range = Range(match.range, in: string) else { return nil }
        return String(string[range])
    }

    /// The captured groups of the first match, excluding the whole-match group.
    func firstMatchGroups(in string: String) -> [String]? {
        guard let match = firstMatch(in: string, options: [], range: fullRange(of: string)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: string).map { String(string[$0]) }
        }
    }
}

#if canImport(VisionKit) && canImport(SwiftUI)
/// Presents the system document scanner and reports the first scanned page.
struct DocumentScannerView: UIViewControllerRepresentable {
    var completion: (Result<UIImage, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let completion: (Result<UIImage, Error>) -> Void

        init(completion: @escaping (Result<UIImage, Error>) -> Void) {
            self.completion = completion
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion(.failure(InvoiceOCRError.scanCancelled))
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(.failure(error))
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else {
                completion(.failure(InvoiceOCRError.invalidImage))
                return
            }
            completion(.success(scan.imageOfPage(at: 0)))
        }
    }
}
#endif
