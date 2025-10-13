import Foundation
import Combine

/// Owns Google Drive link state and schedules background invoice syncs.
@MainActor
final class GoogleDriveConnector: NSObject, ObservableObject, InvoiceAutoSyncScheduling {
    static let imageQualityPreferenceKey = "invoiceImageQualityPreference"

    @Published private(set) var state: GoogleDriveAuthorizationState
    @Published private(set) var linkedFolderName: String?

    let transferService: CloudStorageTransferService
    private let syncCoordinator: GoogleDriveSyncCoordinating
    private let tracker: InvoiceSyncTracker
    private var autoSyncTask: Task<Void, Never>? = nil

    var invoicesProvider: () -> [CapturedInvoice]
    var syncStatusRefresh: () -> Void

    init(transferService: CloudStorageTransferService,
         syncCoordinator: GoogleDriveSyncCoordinating,
         tracker: InvoiceSyncTracker,
         invoicesProvider: @escaping () -> [CapturedInvoice] = { [] },
         syncStatusRefresh: @escaping () -> Void = {}) {
        self.transferService = transferService
        self.syncCoordinator = syncCoordinator
        self.tracker = tracker
        self.invoicesProvider = invoicesProvider
        self.syncStatusRefresh = syncStatusRefresh
        state = transferService.currentAuthorizationState()
        linkedFolderName = transferService.currentUserID != nil ? GoogleDriveTransferService.Constants.defaultFolderName : nil
    }

    func authorizationState() -> GoogleDriveAuthorizationState {
        transferService.currentAuthorizationState()
    }

    func updateInvoicesProvider(_ provider: @escaping () -> [CapturedInvoice]) {
        invoicesProvider = provider
    }

    func updateSyncStatusRefresh(_ refresh: @escaping () -> Void) {
        syncStatusRefresh = refresh
    }

    func linkAccount() async {
        await MainActor.run { self.state = .authorizing }

        do {
            try await transferService.authorize()
            try await transferService.ensureFolder(named: GoogleDriveTransferService.Constants.defaultFolderName)
            await MainActor.run {
                self.state = .linked
                self.linkedFolderName = GoogleDriveTransferService.Constants.defaultFolderName
            }
            syncStatusRefresh()
            let archivedInvoices = invoicesProvider()
            enqueueAutoSync(with: archivedInvoices)
        } catch {
            await MainActor.run { self.state = .failed }
        }
    }

    func unlinkAccount() {
        transferService.disconnect()
        state = .signedOut
        linkedFolderName = nil
        autoSyncTask?.cancel()
        autoSyncTask = nil
        Task {
            await tracker.reset()
        }
    }

    func syncInvoices(_ invoices: [CapturedInvoice], quality: InvoiceImageQuality) async throws -> Int {
        try await syncCoordinator.syncInvoices(invoices, quality: quality)
    }

    func enqueueAutoSync(with invoices: [CapturedInvoice]) {
        guard state == .linked, !invoices.isEmpty else { return }

        autoSyncTask?.cancel()
        autoSyncTask = Task {
            let qualityRaw = UserDefaults.standard.string(forKey: Self.imageQualityPreferenceKey) ?? InvoiceImageQuality.large.rawValue
            let quality = InvoiceImageQuality(rawValue: qualityRaw) ?? .large

            var delay: UInt64 = 1_000_000_000
            let maximumDelay: UInt64 = 60_000_000_000

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                guard self.state == .linked else { return }

                do {
                    _ = try await self.syncInvoices(invoices, quality: quality)
                    await MainActor.run {
                        self.syncStatusRefresh()
                    }
                    return
                } catch {
                    if let syncError = error as? GoogleDriveSyncCoordinator.SyncError {
                        switch syncError {
                        case .missingUserIdentity:
                            return
                        }
                    }

                    delay = min(delay * 2, maximumDelay)
                }
            }
        }
    }
}
