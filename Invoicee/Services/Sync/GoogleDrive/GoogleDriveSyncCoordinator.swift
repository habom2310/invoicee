import Foundation

protocol GoogleDriveSyncCoordinating {
    func syncInvoices(_ invoices: [CapturedInvoice],
                      quality: InvoiceImageQuality) async throws -> GoogleDriveSyncCoordinator.SyncOutcome
}

/// Coordinates uploading invoices and metadata to Google Drive + Firestore.
final class GoogleDriveSyncCoordinator: GoogleDriveSyncCoordinating {
    struct SyncOutcome {
        let invoices: [CapturedInvoice]
        var count: Int { invoices.count }
    }

    enum SyncError: LocalizedError {
        case missingUserIdentity

        var errorDescription: String? {
            switch self {
            case .missingUserIdentity: "Unable to determine the linked Google account."
            }
        }
    }

    /// Where an invoice's attachment ended up, as recorded against the sync tracker.
    private struct Attachment {
        var imageFileName: String?
        var pdfFileName: String?
        var imagePath: String?
        var pdfPath: String?
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
        AppLog.driveSync.info("Sync requested for \(invoices.count) invoices.")

        var pending: [(invoice: CapturedInvoice, record: InvoiceSyncTracker.Record?)] = []
        for invoice in invoices {
            guard await !tracker.isUpToDate(invoice) else { continue }
            pending.append((invoice, await tracker.record(for: invoice.id)))
        }

        guard !pending.isEmpty else { return SyncOutcome(invoices: []) }
        AppLog.driveSync.debug("Invoices needing sync: \(pending.count)")

        guard let userID = transferService.currentUserID else {
            AppLog.driveSync.error("Cannot sync invoices: missing Google Drive user ID.")
            throw SyncError.missingUserIdentity
        }

        let allocator = IncrementAllocator(lookup: await tracker.highestIncrementLookup())
        var syncedInvoices: [CapturedInvoice] = []

        for (invoice, previousRecord) in pending {
            AppLog.driveSync.debug("Processing invoice \(invoice.id) for supplier \(invoice.supplier).")
            let attachment = try await synchronizeAttachment(for: invoice,
                                                             previousRecord: previousRecord,
                                                             quality: quality,
                                                             allocator: allocator)

            try await firestoreUploader.upload(invoice: invoice,
                                               imageFileName: attachment.imageFileName,
                                               pdfFileName: attachment.pdfFileName,
                                               userID: userID)
            await tracker.markSynced(invoice: invoice,
                                     imagePath: attachment.imagePath,
                                     pdfPath: attachment.pdfPath)
            syncedInvoices.append(invoice)
        }

        AppLog.driveSync.info("Sync completed. Synced invoices: \(syncedInvoices.count)")
        return SyncOutcome(invoices: syncedInvoices)
    }

    // MARK: - Attachments

    /// Uploads the invoice's PDF or image when it is new or has moved, and reports the
    /// remote names/paths to persist. A PDF always takes precedence over an image.
    private func synchronizeAttachment(for invoice: CapturedInvoice,
                                       previousRecord: InvoiceSyncTracker.Record?,
                                       quality: InvoiceImageQuality,
                                       allocator: IncrementAllocator) async throws -> Attachment {
        let baseName = DriveUploadMetadata.baseName(for: invoice.date, supplier: invoice.supplier)

        if let pdfData = invoice.pdfData, !pdfData.isEmpty {
            let metadata = makeMetadata(for: invoice,
                                        baseName: baseName,
                                        fileExtension: "pdf",
                                        previousPath: previousRecord?.pdfPath,
                                        allocator: allocator)
            if previousRecord?.pdfPath != metadata.drivePath {
                AppLog.driveSync.debug("Invoice \(invoice.id) PDF requires update. Old: \(previousRecord?.pdfPath ?? "nil"), new: \(metadata.drivePath)")
                try await upload(metadata: metadata, previousPath: previousRecord?.pdfPath) {
                    try InvoiceDriveExporter.exportInvoicePDF(invoice, metadata: metadata)
                }
            }
            return Attachment(pdfFileName: metadata.fileName, pdfPath: metadata.drivePath)
        }

        if let metadata = metadataForRemoteFile(named: invoice.remotePDFFileName,
                                               invoice: invoice,
                                               baseName: baseName,
                                               defaultExtension: "pdf",
                                               allocator: allocator) {
            return Attachment(pdfFileName: invoice.remotePDFFileName, pdfPath: metadata.drivePath)
        }

        if let imageData = invoice.imageData, !imageData.isEmpty {
            let metadata = makeMetadata(for: invoice,
                                        baseName: baseName,
                                        fileExtension: "jpg",
                                        previousPath: previousRecord?.imagePath,
                                        allocator: allocator)
            if previousRecord?.imagePath != metadata.drivePath {
                AppLog.driveSync.debug("Invoice \(invoice.id) image requires update. Old: \(previousRecord?.imagePath ?? "nil"), new: \(metadata.drivePath)")
                try await upload(metadata: metadata, previousPath: previousRecord?.imagePath) {
                    try InvoiceDriveExporter.exportInvoiceImage(invoice, metadata: metadata, quality: quality)
                }
            }
            return Attachment(imageFileName: metadata.fileName, imagePath: metadata.drivePath)
        }

        if let metadata = metadataForRemoteFile(named: invoice.remoteImageFileName,
                                                invoice: invoice,
                                                baseName: baseName,
                                                defaultExtension: "jpg",
                                                allocator: allocator) {
            return Attachment(imageFileName: invoice.remoteImageFileName, imagePath: metadata.drivePath)
        }

        return Attachment()
    }

    /// Moves the previous upload if the invoice's date or supplier changed, then uploads
    /// the freshly exported file. `export` writes a temporary file that is removed after.
    private func upload(metadata: DriveUploadMetadata,
                        previousPath: String?,
                        export: () throws -> URL?) async throws {
        if let previousPath {
            try await transferService.relocateFileIfNeeded(from: previousPath, to: metadata)
        }
        guard let fileURL = try export() else { return }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await transferService.upload(fileURL: fileURL, metadata: metadata)
        AppLog.driveSync.info("Uploaded invoice attachment to Drive as \(metadata.fileName)")
    }

    /// Metadata for a new upload, reusing the previous increment when the invoice still
    /// maps to the same base name so re-syncs overwrite rather than pile up.
    private func makeMetadata(for invoice: CapturedInvoice,
                              baseName: String,
                              fileExtension: String,
                              previousPath: String?,
                              allocator: IncrementAllocator) -> DriveUploadMetadata {
        let preserved = previousPath
            .flatMap(DriveUploadMetadata.parseFileName(from:))
            .flatMap { $0.baseName == baseName ? $0.increment : nil }

        return DriveUploadMetadata(invoiceDate: invoice.date,
                                   supplier: invoice.supplier,
                                   baseFolderName: baseFolderName,
                                   fileExtension: fileExtension,
                                   increment: allocator.next(preserving: preserved, for: baseName))
    }

    /// Metadata describing a file already uploaded under `fileName`, or `nil` when there
    /// is no such file or the name no longer matches the invoice (date or supplier
    /// changed, so the attachment needs re-uploading under a new name instead).
    private func metadataForRemoteFile(named fileName: String?,
                                       invoice: CapturedInvoice,
                                       baseName: String,
                                       defaultExtension: String,
                                       allocator: IncrementAllocator) -> DriveUploadMetadata? {
        guard let fileName = fileName?.nilIfEmpty,
              let parsed = DriveUploadMetadata.parseFileName(from: fileName),
              parsed.baseName == baseName else { return nil }

        allocator.observe(parsed.increment, for: baseName)
        let parsedExtension = URL(fileURLWithPath: fileName).pathExtension

        return DriveUploadMetadata(invoiceDate: invoice.date,
                                   supplier: invoice.supplier,
                                   baseFolderName: baseFolderName,
                                   fileExtension: parsedExtension.nilIfEmpty ?? defaultExtension,
                                   increment: parsed.increment,
                                   imageNumber: parsed.imageNumber)
    }
}

/// Hands out per-base-name upload increments for one sync pass.
private final class IncrementAllocator {
    private var lookup: [String: Int]

    init(lookup: [String: Int]) {
        self.lookup = lookup
    }

    func observe(_ increment: Int, for baseName: String) {
        lookup[baseName] = max(lookup[baseName] ?? 0, increment)
    }

    func next(preserving preserved: Int?, for baseName: String) -> Int {
        if let preserved {
            observe(preserved, for: baseName)
            return preserved
        }
        let next = (lookup[baseName] ?? 0) + 1
        lookup[baseName] = next
        return next
    }
}
