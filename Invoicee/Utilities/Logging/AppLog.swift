import Foundation
#if canImport(os)
import os.log
#endif

/// Category-scoped logging for the sync services.
///
/// Replaces three copy-pasted `private enum …Log` blocks — one per Drive file — that
/// each redeclared the same debug/info/error trio and the same `#if canImport(os)`
/// fallback. Categories are declared once here so a new one cannot arrive with a
/// mismatched subsystem.
nonisolated struct AppLog {
    static let drive = AppLog(category: "GoogleDrive")
    static let driveConnector = AppLog(category: "GoogleDriveConnector")
    static let driveSync = AppLog(category: "GoogleDriveSync")
    static let store = AppLog(category: "LocalInvoiceStore")

    private static let subsystem = "ha.Invoicee"

#if canImport(os)
    private let logger: Logger

    private init(category: String) {
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    func info(_ message: String) { logger.log("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
#else
    private let category: String

    private init(category: String) {
        self.category = category
    }

    func debug(_ message: String) { print("[\(category)][DEBUG] \(message)") }
    func info(_ message: String) { print("[\(category)][INFO] \(message)") }
    func error(_ message: String) { print("[\(category)][ERROR] \(message)") }
#endif
}
