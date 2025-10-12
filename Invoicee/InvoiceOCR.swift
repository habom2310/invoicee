import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(VisionKit)
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
        case .unavailable:
            return "Invoice OCR is not available on this device."
        case .invalidImage:
            return "The scanned image could not be processed."
        case .recognitionFailed:
            return "Unable to extract text from the invoice."
        case .scanCancelled:
            return "Scan cancelled."
        }
    }
}

struct InvoiceOCRResult {
    var data: ManualInvoiceData
    var rawLines: [String]
}

enum InvoiceOCRProcessor {
#if canImport(Vision) && canImport(UIKit)
    static func process(image: UIImage, knownSuppliers: [String] = []) async throws -> InvoiceOCRResult {
        guard let cgImage = image.cgImage else {
            throw InvoiceOCRError.invalidImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw InvoiceOCRError.recognitionFailed
        }

        let entries = observations.compactMap { RecognizedEntry(observation: $0) }
        let lines = entries.map { $0.text }

        var data = ManualInvoiceData()

        if let matchedSupplier = matchSupplier(in: lines, knownSuppliers: knownSuppliers) {
            data.supplier = matchedSupplier
        }

        if data.supplier.trimmed.isEmpty {
            data.supplier = lines.first ?? ""
        }
        if let detectedDate = findDate(in: entries) {
            data.date = detectedDate
        }

        let priceRegex = currencyRegex
        var usedPriceIDs = Set<UUID>()

        if data.totalAmount == nil,
           let total = findTotalAmount(in: entries, priceRegex: priceRegex) {
            data.totalAmount = total.amount
            data.ourAmount = total.amount
            usedPriceIDs.insert(total.priceEntryID)
        }

        if data.items.isEmpty {
            let itemExtraction = extractLineItems(from: entries, priceRegex: priceRegex, excludingPriceIDs: usedPriceIDs)
            data.items = itemExtraction.items
            usedPriceIDs.formUnion(itemExtraction.usedPriceIDs)
        }

        if data.gstAmount == nil,
           let gst = findGSTAmount(in: entries, priceRegex: priceRegex, usedPriceIDs: usedPriceIDs) {
            data.gstAmount = gst.amount
            usedPriceIDs.insert(gst.priceEntryID)
        }

        if data.totalAmount == nil,
           let fallback = fallbackTotal(from: entries, excludingPriceIDs: usedPriceIDs, priceRegex: priceRegex) {
            data.totalAmount = fallback
            if data.ourAmount == nil {
                data.ourAmount = fallback
            }
        }

        if data.ourAmount == nil {
            data.ourAmount = data.totalAmount
        }

        data.gstAmount = GSTValidator.sanitizedAmount(for: data.gstAmount, total: data.totalAmount)
        data.items = filteredItems(data.items, total: data.totalAmount)
        data.hasCustomOurAmount = false

        return InvoiceOCRResult(data: data, rawLines: lines)
    }

    private static func findDate(in entries: [RecognizedEntry]) -> Date? {
        let patterns = [
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#,
            #"\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b"#
        ]

        for entry in entries {
            for pattern in patterns {
                if let dateString = firstMatch(in: entry.text, pattern: pattern),
                   let parsed = parseDate(from: dateString) {
                    return parsed
                }
            }
        }

        return nil
    }

    private static func extractLineItems(from entries: [RecognizedEntry],
                                         priceRegex: NSRegularExpression,
                                         excludingPriceIDs: Set<UUID>) -> (items: [ManualInvoiceItem], usedPriceIDs: Set<UUID>) {
        let rowThreshold: CGFloat = 0.02
        var usedPriceIDs = excludingPriceIDs
        var items: [ManualInvoiceItem] = []

        let priceEntries = entries.filter { entry in
            !usedPriceIDs.contains(entry.id) &&
            matchesCurrency(entry.text, regex: priceRegex) &&
            entry.text.contains("$")
        }

        let nameVerticalTolerance = rowThreshold * 2

        for priceEntry in priceEntries.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            guard let amount = sanitizeCurrency(from: priceEntry.text, using: priceRegex) else { continue }

            let nearbyEntries = entries.filter { abs($0.boundingBox.midY - priceEntry.boundingBox.midY) < nameVerticalTolerance }

            let candidateNames = nearbyEntries
                .filter { $0.boundingBox.midX < priceEntry.boundingBox.midX }
                .filter { nameEntry in
                    let lower = nameEntry.text.lowercased()
                    let containsDollar = nameEntry.text.contains("$")
                    return !containsDollar &&
                        !matchesUnitPrice(nameEntry.text) &&
                        !lower.contains("total") && !lower.contains("subtotal") && !lower.contains("tax") && !lower.contains("gst")
                }
                .sorted { lhs, rhs in
                    let lhsDiff = abs(lhs.boundingBox.midY - priceEntry.boundingBox.midY)
                    let rhsDiff = abs(rhs.boundingBox.midY - priceEntry.boundingBox.midY)
                    if lhsDiff == rhsDiff {
                        return (priceEntry.boundingBox.minX - lhs.boundingBox.maxX) < (priceEntry.boundingBox.minX - rhs.boundingBox.maxX)
                    }
                    return lhsDiff < rhsDiff
                }

            guard let nameEntry = candidateNames.first else { continue }

            let unitPriceEntry = nearbyEntries
                .filter { $0.boundingBox.midX >= nameEntry.boundingBox.minX }
                .first { matchesUnitPrice($0.text) }

            var item = ManualInvoiceItem()
            item.name = nameEntry.text
            item.totalAmount = amount
            if let unitPriceEntry = unitPriceEntry {
                item.unitPrice = unitPriceEntry.text
            }
            items.append(item)
            usedPriceIDs.insert(priceEntry.id)
        }

        return (items, usedPriceIDs)
    }

    private static func findGSTAmount(in entries: [RecognizedEntry],
                                      priceRegex: NSRegularExpression,
                                      usedPriceIDs: Set<UUID>) -> (amount: Decimal, priceEntryID: UUID)? {
        let rowThreshold: CGFloat = 0.02
        let horizontalTolerance: CGFloat = 0.02
        let labelCandidates = entries.filter { entry in
            let lower = entry.text.lowercased()
            return lower.contains("gst") || lower.contains("tax")
        }

        guard !labelCandidates.isEmpty else { return nil }

        let priceEntries = entries.filter { !usedPriceIDs.contains($0.id) && matchesCurrency($0.text, regex: priceRegex) }

        for label in labelCandidates {
            let candidates = priceEntries.filter { entry in
                abs(entry.boundingBox.midY - label.boundingBox.midY) < rowThreshold &&
                entry.boundingBox.minX > label.boundingBox.midX - horizontalTolerance
            }

            if let priceEntry = candidates.min(by: { lhs, rhs in
                abs(lhs.boundingBox.midY - label.boundingBox.midY) < abs(rhs.boundingBox.midY - label.boundingBox.midY)
            }),
               let amountText = sanitizeCurrency(from: priceEntry.text, using: priceRegex),
               let decimalAmount = decimal(from: amountText) {
                return (decimalAmount, priceEntry.id)
            }
        }

        return nil
    }

    private static func findTotalAmount(in entries: [RecognizedEntry], priceRegex: NSRegularExpression) -> (amount: Decimal, priceEntryID: UUID)? {
        let rowThreshold: CGFloat = 0.025
        let labelCandidates = entries.filter { entry in
            let lower = entry.text.lowercased()
            return lower.contains("total") || lower.contains("amount due") || lower.contains("balance")
        }

        let priceEntries = entries.filter { matchesCurrency($0.text, regex: priceRegex) }
        var bestMatch: (amount: Decimal, priceEntryID: UUID, y: CGFloat)?
        let horizontalTolerance: CGFloat = 0.02

        for label in labelCandidates {
            let candidates = priceEntries.filter { entry in
                abs(entry.boundingBox.midY - label.boundingBox.midY) < rowThreshold &&
                entry.boundingBox.minX > label.boundingBox.midX - horizontalTolerance
            }

            guard let priceEntry = candidates.min(by: { lhs, rhs in
                abs(lhs.boundingBox.midY - label.boundingBox.midY) < abs(rhs.boundingBox.midY - label.boundingBox.midY)
            }) else { continue }

            guard let amountText = sanitizeCurrency(from: priceEntry.text, using: priceRegex),
                  let decimalAmount = decimal(from: amountText) else { continue }

            let candidate = (amount: decimalAmount, priceEntryID: priceEntry.id, y: priceEntry.boundingBox.minY)
            if bestMatch == nil || candidate.y < bestMatch!.y {
                bestMatch = candidate
            }
        }

        return bestMatch.map { ($0.amount, $0.priceEntryID) }
    }

    private static func fallbackTotal(from entries: [RecognizedEntry],
                                       excludingPriceIDs: Set<UUID>,
                                       priceRegex: NSRegularExpression) -> Decimal? {
        let priceEntries = entries
            .filter { !excludingPriceIDs.contains($0.id) && matchesCurrency($0.text, regex: priceRegex) }
            .sorted { $0.boundingBox.minY < $1.boundingBox.minY }

        for entry in priceEntries {
            if let amountText = sanitizeCurrency(from: entry.text, using: priceRegex),
               let decimalAmount = decimal(from: amountText) {
                return decimalAmount
            }
        }
        return nil
    }

    private static func matchesCurrency(_ text: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func sanitizeCurrency(from text: String, using regex: NSRegularExpression) -> String? {
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        if let swiftRange = Range(match.range, in: text) {
            return text[swiftRange].replacingOccurrences(of: " ", with: "")
        }
        return nil
    }

    private static func decimal(from currencyString: String) -> Decimal? {
        let cleaned = currencyString
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned)
    }

    private static func matchesUnitPrice(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return unitPriceRegex.firstMatch(in: text.lowercased(), options: [], range: range) != nil
    }

    private static func firstMatch(in line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
        if let swiftRange = Range(match.range, in: line) {
            return String(line[swiftRange])
        }
        return nil
    }

    private static func parseDate(from string: String) -> Date? {
        let pattern = #"(\d{1,2})\D+(\d{1,2})\D+(\d{2,4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(location: 0, length: string.utf16.count)

        guard let match = regex.firstMatch(in: string, options: [], range: range), match.numberOfRanges == 4,
              let dayRange = Range(match.range(at: 1), in: string),
              let monthRange = Range(match.range(at: 2), in: string),
              let yearRange = Range(match.range(at: 3), in: string) else {
            return nil
        }

        var day = String(string[dayRange])
        var month = String(string[monthRange])
        var year = String(string[yearRange])

        if year.count == 2 {
            year = "20" + year
        }

        day = day.count == 1 ? "0" + day : day
        month = month.count == 1 ? "0" + month : month

        let normalized = "\(day)-\(month)-\(year)"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy"
        return formatter.date(from: normalized)
    }

    private static let currencyRegex: NSRegularExpression = {
        let pattern = #"\$?\s*(\d{1,3}(,\d{3})*|\d+)(\.\d{2})?"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let unitPriceRegex: NSRegularExpression = {
        let pattern = #"\b\d+(?:\.\d+)?\s*/\s*(ea|kg|g|lb|ml|l|pack|pc)s?\b"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()
#else
    static func process(image: Any, knownSuppliers: [String] = []) async throws -> InvoiceOCRResult {
        throw InvoiceOCRError.unavailable
    }
#endif
    private static func filteredItems(_ items: [ManualInvoiceItem], total: Decimal?) -> [ManualInvoiceItem] {
        guard let total, items.count > 1 else { return items }

        return items.filter { item in
            guard let amount = decimal(from: item.totalAmount) else { return true }
            return amount != total
        }
    }

    private static func matchSupplier(in lines: [String], knownSuppliers: [String]) -> String? {
        let normalizedSuppliers: [(original: String, normalized: String)] = knownSuppliers
            .map { ($0, $0.trimmed.lowercased()) }
            .filter { !$0.normalized.isEmpty }

        guard !normalizedSuppliers.isEmpty else { return nil }

        let normalizedLines = lines
            .map { $0.trimmed.lowercased() }
            .filter { !$0.isEmpty }

        for line in normalizedLines {
            if let exact = normalizedSuppliers.first(where: { line == $0.normalized }) {
                return exact.original
            }
        }

        let combinedText = normalizedLines.joined(separator: " ")
        for supplier in normalizedSuppliers {
            if combinedText.contains(supplier.normalized) {
                return supplier.original
            }
        }

        return nil
    }
}

#if canImport(Vision)
private struct RecognizedEntry {
    let id = UUID()
    let text: String
    let boundingBox: CGRect

    init?(observation: VNRecognizedTextObservation) {
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.text = trimmed
        self.boundingBox = observation.boundingBox
    }
}
#endif

#if canImport(VisionKit) && canImport(SwiftUI)
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
            controller.dismiss(animated: true) {
                self.completion(.failure(InvoiceOCRError.scanCancelled))
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true) {
                self.completion(.failure(error))
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            controller.dismiss(animated: true) {
                guard scan.pageCount > 0 else {
                    self.completion(.failure(InvoiceOCRError.invalidImage))
                    return
                }

                let image = scan.imageOfPage(at: 0)
                self.completion(.success(image))
            }
        }
    }
}
#endif
