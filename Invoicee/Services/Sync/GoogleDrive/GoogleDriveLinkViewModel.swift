import Foundation
import Combine

/// View model backing the Google Drive linking UI.
@MainActor
final class GoogleDriveLinkViewModel: ObservableObject {
    @Published private(set) var authorizationState: GoogleDriveAuthorizationState
    @Published private(set) var linkedFolderName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncStatusMessage: String?
    @Published var imageQuality: InvoiceImageQuality {
        didSet {
            UserDefaults.standard.set(imageQuality.rawValue, forKey: GoogleDriveConnector.imageQualityPreferenceKey)
        }
    }

    private let connector: GoogleDriveConnector
    private let archive: InvoiceArchive
    private var subscriptions = Set<AnyCancellable>()

    init(connector: GoogleDriveConnector, archive: InvoiceArchive) {
        self.connector = connector
        self.archive = archive
        authorizationState = connector.authorizationState()
        linkedFolderName = connector.linkedFolderName
        imageQuality = InvoiceImageQuality(rawValue: UserDefaults.standard.string(forKey: GoogleDriveConnector.imageQualityPreferenceKey) ?? "") ?? .large

        connector.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$authorizationState)

        connector.$linkedFolderName
            .receive(on: DispatchQueue.main)
            .assign(to: &$linkedFolderName)
    }

    func linkAccount() {
        errorMessage = nil
        syncStatusMessage = nil

        Task {
            await connector.linkAccount()
            if connector.state == .failed {
                await MainActor.run {
                    self.errorMessage = self.connectorStateErrorMessage()
                }
            }
        }
    }

    func unlinkAccount() {
        connector.unlinkAccount()
        syncStatusMessage = nil
    }

    func syncInvoices() {
        errorMessage = nil
        syncStatusMessage = nil

        guard authorizationState == .linked else {
            errorMessage = "Link Google Drive before syncing."
            return
        }

        let invoices = archive.invoices
        guard !invoices.isEmpty else {
            syncStatusMessage = "No invoices available to sync."
            return
        }

        isSyncing = true
        syncStatusMessage = "Preparing invoices for sync…"

        Task {
            do {
                let quality = self.imageQuality
                let syncedCount = try await connector.syncInvoices(invoices, quality: quality)
                self.isSyncing = false
                self.errorMessage = nil
                if syncedCount == 0 {
                    self.syncStatusMessage = "All invoices already synced."
                } else if syncedCount == 1 {
                    self.syncStatusMessage = "Synced 1 invoice to Google Drive and Firestore."
                } else {
                    self.syncStatusMessage = "Synced \(syncedCount) invoices to Google Drive and Firestore."
                }
            } catch {
                self.isSyncing = false
                self.syncStatusMessage = nil
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func connectorStateErrorMessage() -> String {
        if let error = (connector.transferService as? GoogleDriveTransferService)?.lastErrorDescription {
            return error
        }
        return "Failed to link Google Drive. Please try again."
    }
}
