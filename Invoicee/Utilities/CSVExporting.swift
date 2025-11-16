import Foundation

/// Shared helpers for building CSV text and sending exports to Google Drive.
enum CSVExporting {
    static func escape(_ value: String) -> String {
        let needsEscaping = value.contains(",") || value.contains("\n") || value.contains("\"")
        guard needsEscaping else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    static func makeCSV(from rows: [[String]]) -> String {
        rows
            .map { row in row.map(CSVExporting.escape).joined(separator: ",") }
            .joined(separator: "\n")
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
