import Foundation

protocol GoogleDriveSyncCoordinating {
    func syncInvoices(_ invoices: [CapturedInvoice], quality: InvoiceImageQuality) async throws -> Int
}

/// Coordinates uploading invoices and metadata to Google Drive + Firestore.
final class GoogleDriveSyncCoordinator: GoogleDriveSyncCoordinating {
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

    func syncInvoices(_ invoices: [CapturedInvoice], quality: InvoiceImageQuality) async throws -> Int {
        guard !invoices.isEmpty else { return 0 }
        var incrementLookup = await tracker.highestIncrementLookup()
        var pendingInvoices: [(CapturedInvoice, InvoiceSyncTracker.Record?)] = []
        for invoice in invoices {
            if await tracker.isUpToDate(invoice) { continue }
            let record = await tracker.record(for: invoice.id)
            pendingInvoices.append((invoice, record))
        }

        guard !pendingInvoices.isEmpty else { return 0 }

        guard let userID = transferService.currentUserID else {
            throw SyncError.missingUserIdentity
        }

        var syncedCount = 0
        var driveFolderEnsured = false

        for (invoice, previousRecord) in pendingInvoices {
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
                    if !driveFolderEnsured {
                        try await transferService.ensureFolder(named: baseFolderName)
                        driveFolderEnsured = true
                    }

                    if let imageURL = try InvoiceDriveExporter.exportInvoiceImage(invoice, metadata: imageMetadata, quality: quality) {
                        try await transferService.upload(fileURL: imageURL, metadata: imageMetadata)
                        try? FileManager.default.removeItem(at: imageURL)
                    }
                }

                imageFileName = imageMetadata.fileName
                imagePathToPersist = expectedPath
            } else {
                imagePathToPersist = nil
            }

            try await firestoreUploader.upload(invoice: invoice, imageFileName: imageFileName, userID: userID)
            await tracker.markSynced(invoice: invoice, imagePath: imagePathToPersist)
            syncedCount += 1
        }

        return syncedCount
    }

    private func drivePath(for metadata: DriveUploadMetadata) -> String {
        "\(metadata.baseFolderName)/\(metadata.yearFolderName)/\(metadata.monthFolderName)/\(metadata.fileName)"
    }
}
