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
            let baseName = DriveUploadMetadata.baseName(for: invoice.date, supplier: invoice.supplier)
            var imageFileName: String? = nil
            var pdfFileName: String? = nil
            var imagePathToPersist: String? = nil
            var pdfPathToPersist: String? = nil

            func nextIncrement(preserved: Int?, for baseName: String) -> Int {
                if let preserved {
                    incrementLookup[baseName] = max(incrementLookup[baseName] ?? 0, preserved)
                    return preserved
                }
                let next = (incrementLookup[baseName] ?? 0) + 1
                incrementLookup[baseName] = next
                return next
            }

            func metadataForExistingFile(named fileName: String, defaultExtension: String) -> DriveUploadMetadata? {
                guard let parsed = DriveUploadMetadata.parseFileName(from: fileName),
                      parsed.baseName == baseName else {
                    return nil
                }
                let ext = (fileName as NSString).pathExtension
                let resolvedExt = ext.isEmpty ? defaultExtension : ext.lowercased()
                incrementLookup[baseName] = max(incrementLookup[baseName] ?? 0, parsed.increment)
                return DriveUploadMetadata(
                    invoiceDate: invoice.date,
                    supplier: invoice.supplier,
                    baseFolderName: baseFolderName,
                    fileExtension: resolvedExt,
                    increment: parsed.increment,
                    imageNumber: parsed.imageNumber
                )
            }

            if let pdfData = invoice.pdfData, !pdfData.isEmpty {
                let preservedIncrement: Int? = {
                    guard let previousPath = previousRecord?.pdfPath,
                          let parsed = DriveUploadMetadata.parseFileName(from: previousPath),
                          parsed.baseName == baseName else {
                        return nil
                    }
                    return parsed.increment
                }()

                let increment = nextIncrement(preserved: preservedIncrement, for: baseName)
                let pdfMetadata = DriveUploadMetadata(
                    invoiceDate: invoice.date,
                    supplier: invoice.supplier,
                    baseFolderName: baseFolderName,
                    fileExtension: "pdf",
                    increment: increment
                )
                let expectedPath = drivePath(for: pdfMetadata)
                let needsUpload = previousRecord?.pdfPath != expectedPath

                if needsUpload {
                    DriveCoordinatorLog.debug("Invoice \(invoice.id) PDF requires update. Old path: \(previousRecord?.pdfPath ?? "nil"), new path: \(expectedPath)")
                    if let previousPath = previousRecord?.pdfPath {
                        try await transferService.relocateFileIfNeeded(from: previousPath, to: pdfMetadata)
                    }

                    if !driveFolderEnsured {
                        try await transferService.ensureFolder(named: baseFolderName)
                        driveFolderEnsured = true
                    }

                    if let pdfURL = try InvoiceDriveExporter.exportInvoicePDF(invoice, metadata: pdfMetadata) {
                        try await transferService.upload(fileURL: pdfURL, metadata: pdfMetadata)
                        try? FileManager.default.removeItem(at: pdfURL)
                        DriveCoordinatorLog.info("Uploaded invoice \(invoice.id) PDF to Drive as \(pdfMetadata.fileName)")
                    }
                }

                pdfFileName = pdfMetadata.fileName
                pdfPathToPersist = expectedPath
                imagePathToPersist = nil
                imageFileName = nil
            } else if let remotePDFName = invoice.remotePDFFileName,
                      !remotePDFName.isEmpty,
                      let metadata = metadataForExistingFile(named: remotePDFName, defaultExtension: "pdf") {
                pdfFileName = remotePDFName
                pdfPathToPersist = drivePath(for: metadata)
                imagePathToPersist = nil
            } else if let imageData = invoice.imageData, !imageData.isEmpty {
                let preservedIncrement: Int? = {
                    guard let previousPath = previousRecord?.imagePath,
                          let parsed = DriveUploadMetadata.parseFileName(from: previousPath),
                          parsed.baseName == baseName else {
                        return nil
                    }
                    return parsed.increment
                }()

                let increment = nextIncrement(preserved: preservedIncrement, for: baseName)
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
                pdfPathToPersist = nil
            } else if let remoteImageName = invoice.remoteImageFileName,
                      !remoteImageName.isEmpty,
                      let metadata = metadataForExistingFile(named: remoteImageName, defaultExtension: "jpg") {
                imageFileName = remoteImageName
                imagePathToPersist = drivePath(for: metadata)
                pdfPathToPersist = nil
            } else {
                imagePathToPersist = nil
                pdfPathToPersist = nil
            }

            try await firestoreUploader.upload(invoice: invoice,
                                               imageFileName: imageFileName,
                                               pdfFileName: pdfFileName,
                                               userID: userID)
            await tracker.markSynced(invoice: invoice,
                                     imagePath: imagePathToPersist,
                                     pdfPath: pdfPathToPersist)
            syncedInvoices.append(invoice)
        }

        DriveCoordinatorLog.info("Sync completed. Synced invoices: \(syncedInvoices.count)")
        return SyncOutcome(invoices: syncedInvoices)
    }

    private func drivePath(for metadata: DriveUploadMetadata) -> String {
        "\(metadata.baseFolderName)/\(metadata.yearFolderName)/\(metadata.monthFolderName)/\(metadata.fileName)"
    }
}
