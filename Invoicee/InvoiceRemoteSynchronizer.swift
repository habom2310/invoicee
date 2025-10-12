import Foundation

@MainActor
final class InvoiceRemoteSynchronizer {
    static let shared = InvoiceRemoteSynchronizer()

    private var isSyncing = false

    private init() {}

    /// Synchronizes invoices from Firestore into the local archive if the user is linked.
    /// - Returns: `true` when new or updated invoices were merged into the archive.
    func synchronizeFromRemote() async throws -> Bool {
        guard !isSyncing else { return false }

        let connector = GoogleDriveConnector.shared
        guard connector.authorizationState() == .linked,
              let userID = connector.transferService.currentUserID else {
            return false
        }

        isSyncing = true
        defer { isSyncing = false }

        let remoteInvoices = try await InvoiceFirestoreUploader.shared.fetchInvoices(for: userID)
        guard !remoteInvoices.isEmpty else { return false }

        let localInvoices = InvoiceArchive.shared.invoices
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

        InvoiceArchive.shared.update(with: mergedList)
        return true
    }
}
