import Foundation

/// Bridges the local archive and remote storage: pulls remote invoices in, and answers
/// the connector's questions about what to push out.
@MainActor
final class InvoiceRemoteSynchronizer: InvoiceSyncHost {
    private let connector: GoogleDriveConnector
    private let archive: InvoiceArchive
    private let firestoreUploader: InvoiceFirestoreUploading
    private var isSyncing = false

    init(connector: GoogleDriveConnector,
         archive: InvoiceArchive,
         firestoreUploader: InvoiceFirestoreUploading) {
        self.connector = connector
        self.archive = archive
        self.firestoreUploader = firestoreUploader
    }

    // MARK: - InvoiceSyncHost

    var invoicesToSync: [CapturedInvoice] {
        archive.invoices
    }

    func refreshSyncStatus() {
        archive.refreshSyncStatus()
    }

    func removeAllInvoices() {
        archive.removeAll()
    }

    func fetchRemoteInvoices() async {
        // The connector drives this as part of link reconciliation and has no UI to
        // surface a failure on; the screens that can report one call
        // `synchronizeFromRemote()` directly.
        _ = try? await synchronizeFromRemote()
    }

    // MARK: - Pulling

    /// Synchronizes invoices from Firestore into the local archive if the user is linked.
    /// - Returns: `true` when new or updated invoices were merged into the archive.
    @discardableResult
    func synchronizeFromRemote() async throws -> Bool {
        guard !isSyncing else { return false }

        guard connector.authorizationState() == .linked,
              let userID = connector.currentAccountID else {
            return false
        }

        isSyncing = true
        defer { isSyncing = false }

        let remoteInvoices = try await firestoreUploader.fetchInvoices(for: userID)
        guard !remoteInvoices.isEmpty else { return false }

        var merged = Dictionary(uniqueKeysWithValues: archive.invoices.map { ($0.id, $0) })
        var didChange = false

        for remote in remoteInvoices {
            guard let existing = merged[remote.id] else {
                merged[remote.id] = remote
                didChange = true
                continue
            }

            guard let updated = Self.merging(remote: remote, into: existing) else { continue }
            merged[remote.id] = updated
            didChange = true
        }

        guard didChange else { return false }

        archive.update(with: merged.values.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.lastEdited > rhs.lastEdited : lhs.date > rhs.date
        })
        return true
    }

    /// Takes the remote field values but keeps attachments that only exist locally.
    ///
    /// Firestore never carries the image/PDF bytes, so replacing the local invoice
    /// wholesale would discard the captured file and the remote file names it was
    /// uploaded under.
    ///
    /// - Returns: the merged invoice, or `nil` when the remote copy has nothing to add.
    private static func merging(remote: CapturedInvoice, into local: CapturedInvoice) -> CapturedInvoice? {
        let isNewer = remote.lastEdited > local.lastEdited
        let addsImageReference = local.remoteImageFileName == nil && remote.remoteImageFileName != nil
        let addsPDFReference = local.remotePDFFileName == nil && remote.remotePDFFileName != nil
        guard isNewer || addsImageReference || addsPDFReference else { return nil }

        // A stale remote copy may still carry a file name the local one is missing, so
        // take the field values only when the remote copy is genuinely newer.
        var merged = isNewer ? remote : local
        merged.imageData = local.imageData
        merged.pdfData = local.pdfData
        merged.remoteImageFileName = remote.remoteImageFileName ?? local.remoteImageFileName
        merged.remotePDFFileName = remote.remotePDFFileName ?? local.remotePDFFileName
        return merged == local ? nil : merged
    }
}
