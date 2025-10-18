import Foundation
import Combine

/// View model backing the Google Drive section in the profile tab.
@MainActor
final class GoogleDriveLinkViewModel: ObservableObject {
    @Published private(set) var authorizationState: GoogleDriveAuthorizationState
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSyncing: Bool
    @Published private(set) var syncStatusMessage: String?
    @Published private(set) var hasUnsyncedInvoices: Bool
    @Published var imageQuality: InvoiceImageQuality {
        didSet {
            UserDefaults.standard.set(imageQuality.rawValue, forKey: GoogleDriveConnector.imageQualityPreferenceKey)
        }
    }

    private let connector: GoogleDriveConnector
    private let archive: InvoiceArchive
    init(connector: GoogleDriveConnector, archive: InvoiceArchive) {
        self.connector = connector
        self.archive = archive
        authorizationState = connector.authorizationState()
        accountDisplayName = connector.accountDisplayName
        errorMessage = connector.linkIssueMessage
        isSyncing = connector.isSyncing
        syncStatusMessage = connector.lastSyncSummary
        hasUnsyncedInvoices = connector.hasUnsyncedInvoices
        imageQuality = InvoiceImageQuality(rawValue: UserDefaults.standard.string(forKey: GoogleDriveConnector.imageQualityPreferenceKey) ?? "") ?? .large

        connector.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$authorizationState)

        connector.$accountDisplayName
            .receive(on: DispatchQueue.main)
            .assign(to: &$accountDisplayName)

        connector.$linkIssueMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorMessage)

        connector.$isSyncing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isSyncing)

        connector.$lastSyncSummary
            .receive(on: DispatchQueue.main)
            .assign(to: &$syncStatusMessage)

        connector.$hasUnsyncedInvoices
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasUnsyncedInvoices)
    }

    func linkAccount() {
        errorMessage = nil
        syncStatusMessage = nil
        Task { await connector.linkAccount() }
    }

    func unlinkAccount(force: Bool) {
        Task {
            _ = await connector.unlinkAccount(force: force)
        }
    }

    func syncInvoices() {
        errorMessage = nil
        syncStatusMessage = nil

        guard authorizationState == .linked else {
            errorMessage = "Link Google Drive before syncing."
            return
        }

        guard !archive.invoices.isEmpty else {
            syncStatusMessage = "No invoices available to sync."
            return
        }

        Task {
            do {
                try await connector.syncNow(quality: imageQuality)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.errorMessage = message
                }
            }
        }
    }
}
