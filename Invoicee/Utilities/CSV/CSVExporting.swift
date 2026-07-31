import Foundation

/// Shared helpers for building CSV text and sending exports to Google Drive.
///
/// `nonisolated` so an export can be assembled off the main actor.
nonisolated enum CSVExporting {
    /// Quotes a field when it contains a character that would otherwise break the row.
    static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func makeCSV(from rows: [[String]]) -> String {
        rows
            .map { $0.map(escape).joined(separator: ",") }
            .joined(separator: "\n")
    }

    /// Header, one row per invoice, and a totals row — shared by the invoice and expense
    /// exports.
    static func invoiceRows(from invoices: [CapturedInvoice],
                            uncategorizedLabel: String = "") -> [[String]] {
        var rows: [[String]] = [["Date", "Supplier", "Total Amount", "Our Amount", "GST", "Category"]]
        var totals = (total: Decimal.zero, ourAmount: Decimal.zero, gst: Decimal.zero)

        for invoice in invoices {
            rows.append([
                ReportingDateFormatter.isoDay(invoice.date),
                invoice.supplier,
                invoice.total.plainString,
                invoice.ourAmount.plainString,
                invoice.gst.plainString,
                invoice.category ?? uncategorizedLabel
            ])
            // Accumulated in the same pass; three separate `reduce` calls walked the list
            // three more times.
            totals.total += invoice.total
            totals.ourAmount += invoice.ourAmount
            totals.gst += invoice.gst
        }

        rows.append(["",
                     "TOTAL",
                     totals.total.plainString,
                     totals.ourAmount.plainString,
                     totals.gst.plainString,
                     ""])
        return rows
    }

    static func uploadToDrive(content: String,
                              filename: String,
                              transferService: CloudStorageTransferService) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await transferService.uploadExport(fileURL: tempURL, fileName: filename)
    }
}
