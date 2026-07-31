import Foundation

/// Abstracts Drive-specific upload/download operations for testability.
protocol CloudStorageTransferService {
    var currentUserID: String? { get }
    var currentAccountName: String? { get }
    /// The most recent failure the service recorded, if any.
    ///
    /// Part of the protocol because the connector needs it to explain a failed link.
    /// It previously had to downcast to `GoogleDriveTransferService` to reach the same
    /// value, which meant any other conformance silently lost its error messages.
    var lastFailureDescription: String? { get }

    func currentAuthorizationState() -> GoogleDriveAuthorizationState
    func performHealthCheck() async -> GoogleDriveAuthorizationState
    func authorize() async throws
    func disconnect()

    func ensureRootFolder() async throws
    func upload(fileURL: URL, metadata: DriveUploadMetadata) async throws
    func uploadExport(fileURL: URL, fileName: String) async throws
    func relocateFileIfNeeded(from existingPath: String, to metadata: DriveUploadMetadata) async throws
    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data
    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws
}

extension CloudStorageTransferService {
    /// The clearest available description of `error`, preferring the detail the service
    /// recorded while handling it over the generic `Error` description.
    func failureDescription(for error: Error) -> String {
        lastFailureDescription ?? error.userFacingDescription
    }
}
