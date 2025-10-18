import Foundation

/// Abstracts Drive-specific upload/download operations for testability.
protocol CloudStorageTransferService {
    func currentAuthorizationState() -> GoogleDriveAuthorizationState
    func authorize() async throws
    func performHealthCheck() async -> GoogleDriveAuthorizationState
    func disconnect()
    func relocateFileIfNeeded(from existingPath: String, to metadata: DriveUploadMetadata) async throws
    func ensureFolder(named name: String) async throws
    func upload(fileURL: URL, metadata: DriveUploadMetadata) async throws
    func uploadExport(fileURL: URL, fileName: String) async throws
    var currentUserID: String? { get }
    var currentAccountName: String? { get }
    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data
    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws
}
