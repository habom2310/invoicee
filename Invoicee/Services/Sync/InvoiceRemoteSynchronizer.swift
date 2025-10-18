import Foundation

/// Pulls remote invoices into the local archive when Drive is linked.
@MainActor
final class InvoiceRemoteSynchronizer {
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

    /// Synchronizes invoices from Firestore into the local archive if the user is linked.
    /// - Returns: `true` when new or updated invoices were merged into the archive.
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

        let localInvoices = archive.invoices
        var mergedInvoices = Dictionary(uniqueKeysWithValues: localInvoices.map { ($0.id, $0) })
        var didChange = false

        for remote in remoteInvoices {
            if let existing = mergedInvoices[remote.id] {
                let hasNewerTimestamp = remote.lastEdited > existing.lastEdited
                let hasMissingImageReference = existing.remoteImageFileName == nil && remote.remoteImageFileName != nil
                if hasNewerTimestamp || hasMissingImageReference {
                    mergedInvoices[remote.id] = remote
                    didChange = true
                }
            } else {
                mergedInvoices[remote.id] = remote
                didChange = true
            }
        }

        guard didChange else { return false }

        let mergedList = mergedInvoices.values.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.lastEdited > rhs.lastEdited
            }
            return lhs.date > rhs.date
        }

        archive.update(with: mergedList)
        return true
    }
}
