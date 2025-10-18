import Foundation
#if canImport(os)
import os.log
#endif

#if canImport(os)
private enum DriveCoordinatorLog {
    static let logger = Logger(subsystem: "ha.Invoicee", category: "GoogleDriveSync")

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
#else
private enum DriveCoordinatorLog {
    static func debug(_ message: String) { print("[GoogleDriveSync][DEBUG] \(message)") }
    static func info(_ message: String) { print("[GoogleDriveSync][INFO] \(message)") }
    static func error(_ message: String) { print("[GoogleDriveSync][ERROR] \(message)") }
}
#endif

protocol GoogleDriveSyncCoordinating {
    func syncInvoices(_ invoices: [CapturedInvoice], quality: InvoiceImageQuality) async throws -> GoogleDriveSyncCoordinator.SyncOutcome
}

/// Coordinates uploading invoices and metadata to Google Drive + Firestore.
final class GoogleDriveSyncCoordinator: GoogleDriveSyncCoordinating {
    struct SyncOutcome {
        let invoices: [CapturedInvoice]
        var count: Int { invoices.count }
        var invoiceIDs: [UUID] { invoices.map(\.id) }
    }

    enum SyncError: LocalizedError {
        case missingUserIdentity

        var errorDescription: String? {
            switch self {
            case .missingUserIdentity:
                return "Unable to determine the linked Google account."
            }
        }
    }

    private let transferService: CloudStorageTransferService
    private let tracker: InvoiceSyncTracker
    private let firestoreUploader: InvoiceFirestoreUploading
    private let baseFolderName: String

    init(transferService: CloudStorageTransferService,
         tracker: InvoiceSyncTracker,
         firestoreUploader: InvoiceFirestoreUploading,
         baseFolderName: String = GoogleDriveTransferService.Constants.defaultFolderName) {
        self.transferService = transferService
        self.tracker = tracker
        self.firestoreUploader = firestoreUploader
        self.baseFolderName = baseFolderName
    }

    func syncInvoices(_ invoices: [CapturedInvoice], quality: InvoiceImageQuality) async throws -> SyncOutcome {
        guard !invoices.isEmpty else { return SyncOutcome(invoices: []) }
        DriveCoordinatorLog.info("Sync requested for \(invoices.count) invoices.")
        var incrementLookup = await tracker.highestIncrementLookup()
        var pendingInvoices: [(CapturedInvoice, InvoiceSyncTracker.Record?)] = []
        for invoice in invoices {
            if await tracker.isUpToDate(invoice) { continue }
            let record = await tracker.record(for: invoice.id)
            pendingInvoices.append((invoice, record))
        }

        guard !pendingInvoices.isEmpty else { return SyncOutcome(invoices: []) }
        DriveCoordinatorLog.debug("Invoices needing sync: \(pendingInvoices.count)")

        guard let userID = transferService.currentUserID else {
            DriveCoordinatorLog.error("Cannot sync invoices: missing Google Drive user ID.")
            throw SyncError.missingUserIdentity
        }

        var syncedInvoices: [CapturedInvoice] = []
        var driveFolderEnsured = false

        for (invoice, previousRecord) in pendingInvoices {
            DriveCoordinatorLog.debug("Processing invoice \(invoice.id) dated \(invoice.date) for supplier \(invoice.supplier).")
            var imageFileName: String? = nil
            var imagePathToPersist: String? = nil

            if invoice.imageData != nil {
                let baseName = DriveUploadMetadata.baseName(for: invoice.date, supplier: invoice.supplier)
                let preservedIncrement: Int? = {
                    guard let previousPath = previousRecord?.imagePath,
                          let parsed = DriveUploadMetadata.parseFileName(from: previousPath),
                          parsed.baseName == baseName else {
                        return nil
                    }
                    return parsed.increment
                }()
                let increment: Int = {
                    if let preservedIncrement {
                        return preservedIncrement
                    }
                    let next = (incrementLookup[baseName] ?? 0) + 1
                    return next
                }()
                incrementLookup[baseName] = max(incrementLookup[baseName] ?? 0, increment)

                let imageMetadata = DriveUploadMetadata(
                    invoiceDate: invoice.date,
                    supplier: invoice.supplier,
                    baseFolderName: baseFolderName,
                    fileExtension: "jpg",
                    increment: increment
                )

                let expectedPath = drivePath(for: imageMetadata)
                let needsUpload = previousRecord?.imagePath != expectedPath

                if needsUpload {
                    DriveCoordinatorLog.debug("Invoice \(invoice.id) image requires update. Old path: \(previousRecord?.imagePath ?? "nil"), new path: \(expectedPath)")
                    if let previousPath = previousRecord?.imagePath {
                        try await transferService.relocateFileIfNeeded(from: previousPath, to: imageMetadata)
                    }

                    if !driveFolderEnsured {
                        try await transferService.ensureFolder(named: baseFolderName)
                        driveFolderEnsured = true
                    }

                    if let imageURL = try InvoiceDriveExporter.exportInvoiceImage(invoice, metadata: imageMetadata, quality: quality) {
                        try await transferService.upload(fileURL: imageURL, metadata: imageMetadata)
                        try? FileManager.default.removeItem(at: imageURL)
                        DriveCoordinatorLog.info("Uploaded invoice \(invoice.id) image to Drive as \(imageMetadata.fileName)")
                    }
                }

                imageFileName = imageMetadata.fileName
                imagePathToPersist = expectedPath
            } else {
                imagePathToPersist = nil
            }

            try await firestoreUploader.upload(invoice: invoice, imageFileName: imageFileName, userID: userID)
            await tracker.markSynced(invoice: invoice, imagePath: imagePathToPersist)
            syncedInvoices.append(invoice)
        }

        DriveCoordinatorLog.info("Sync completed. Synced invoices: \(syncedInvoices.count)")
        return SyncOutcome(invoices: syncedInvoices)
    }

    private func drivePath(for metadata: DriveUploadMetadata) -> String {
        "\(metadata.baseFolderName)/\(metadata.yearFolderName)/\(metadata.monthFolderName)/\(metadata.fileName)"
    }
}
