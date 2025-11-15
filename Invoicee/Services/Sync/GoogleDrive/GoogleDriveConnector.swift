import Foundation
import Combine
#if canImport(os)
import os.log
#endif

#if canImport(os)
private enum DriveConnectorLog {
    static let logger = Logger(subsystem: "ha.Invoicee", category: "GoogleDriveConnector")

    static func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    static func info(_ message: String) { logger.log("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
#else
private enum DriveConnectorLog {
    static func debug(_ message: String) { print("[GoogleDriveConnector][DEBUG] \(message)") }
    static func info(_ message: String) { print("[GoogleDriveConnector][INFO] \(message)") }
    static func error(_ message: String) { print("[GoogleDriveConnector][ERROR] \(message)") }
}
#endif

/// Central coordinator for Drive authentication, manual sync, and archive hygiene.
@MainActor
final class GoogleDriveConnector: NSObject, ObservableObject, InvoiceAutoSyncScheduling {
    static let imageQualityPreferenceKey = "invoiceImageQualityPreference"

    @Published private(set) var state: GoogleDriveAuthorizationState
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var linkIssueMessage: String?
    @Published private(set) var hasUnsyncedInvoices: Bool = false
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncSummary: String?

    var currentAccountID: String? {
        transferService.currentUserID
    }

    let transferService: CloudStorageTransferService
    private let syncCoordinator: GoogleDriveSyncCoordinating
    private let tracker: InvoiceSyncTracker

    private var invoicesProvider: () -> [CapturedInvoice]
    private var syncStatusRefresh: () -> Void
    private var clearLocalInvoices: () -> Void
    private var removeInvoices: ([UUID]) -> Void
    private var remoteFetcher: (() async -> Void)?
    private var registerSyncedInvoices: ([UUID]) -> Void
    private var hasValidatedDriveSession = false
    private var autoSyncTask: Task<Void, Never>? = nil

    private var unsyncedInvoiceIDs: Set<UUID> = []

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
        self.clearLocalInvoices = {}
        self.removeInvoices = { _ in }
        self.registerSyncedInvoices = { _ in }
        state = transferService.currentAuthorizationState()
        accountDisplayName = transferService.currentAccountName
        linkIssueMessage = nil
        hasValidatedDriveSession = false
        super.init()
        DriveConnectorLog.debug("Connector initialised. State: \(state)")
        Task(priority: .background) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await performStartupHealthCheck()
        }
    }

    func authorizationState() -> GoogleDriveAuthorizationState {
        state
    }

    func updateInvoicesProvider(_ provider: @escaping () -> [CapturedInvoice]) {
        invoicesProvider = provider
    }

    func updateSyncStatusRefresh(_ refresh: @escaping () -> Void) {
        syncStatusRefresh = refresh
    }

    func configureArchiveHandlers(clearAll: @escaping () -> Void,
                                  removeInvoices: @escaping ([UUID]) -> Void) {
        clearLocalInvoices = clearAll
        self.removeInvoices = removeInvoices
    }

    func updateRemoteFetcher(_ fetcher: @escaping () async -> Void) {
        remoteFetcher = fetcher
        if state == .linked {
            Task(priority: .background) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await fetcher()
            }
        }
    }

    func updateSyncedRegistration(_ handler: @escaping ([UUID]) -> Void) {
        registerSyncedInvoices = handler
    }

    func refreshLinkState() {
        Task(priority: .background) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await performStartupHealthCheck()
        }
    }

    /// Launches the Google auth flow and persists the resulting session.
    func linkAccount() async {
        state = .authorizing
        linkIssueMessage = nil
        DriveConnectorLog.info("Starting Google Drive sign-in.")

        do {
            try await transferService.authorize()
            try await transferService.ensureFolder(named: GoogleDriveTransferService.Constants.defaultFolderName)
            state = .linked
            accountDisplayName = transferService.currentAccountName
            linkIssueMessage = nil
            hasValidatedDriveSession = true
            DriveConnectorLog.info("Google Drive linked for \(accountDisplayName ?? transferService.currentUserID ?? "unknown user").")
            await refreshUnsyncedState()
            syncStatusRefresh()
            await remoteFetcher?()
            await refreshUnsyncedState()
            syncStatusRefresh()
        } catch {
            state = .failed
            linkIssueMessage = (transferService as? GoogleDriveTransferService)?.lastErrorDescription ??
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DriveConnectorLog.error("Google Drive link failed: \(linkIssueMessage ?? error.localizedDescription)")
            hasValidatedDriveSession = false
            unsyncedInvoiceIDs.removeAll()
            hasUnsyncedInvoices = false
            lastSyncSummary = nil
        }
    }

    /// Performs a manual synchronization of invoices + Firebase metadata.
    @discardableResult
    func syncNow(quality: InvoiceImageQuality) async throws -> Int {
        guard state == .linked else {
            DriveConnectorLog.error("Sync requested while Drive not linked.")
            throw NSError(domain: "GoogleDriveConnector",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Link Google Drive before syncing."])
        }

        guard !isSyncing else {
            DriveConnectorLog.debug("Sync requested while another sync is running; ignoring.")
            return 0
        }

        isSyncing = true
        lastSyncSummary = "Syncing…"

        do {
            let invoices = invoicesProvider()
            let outcome = try await syncCoordinator.syncInvoices(invoices, quality: quality)
            registerSyncedInvoices(outcome.invoiceIDs)
            unsyncedInvoiceIDs.subtract(outcome.invoiceIDs)
            hasUnsyncedInvoices = !unsyncedInvoiceIDs.isEmpty
            await refreshUnsyncedState(for: invoices)
            syncStatusRefresh()
            isSyncing = false

            if outcome.count == 0 {
                lastSyncSummary = "All invoices already synced."
            } else {
                lastSyncSummary = "Synced \(outcome.count) invoice\(outcome.count == 1 ? "" : "s")."
            }
            DriveConnectorLog.info(lastSyncSummary ?? "Sync completed.")
            return outcome.count
        } catch {
            isSyncing = false
            lastSyncSummary = nil
            DriveConnectorLog.error("Manual sync failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Records that invoices changed; recalculates unsynced set.
    func enqueueAutoSync(with invoices: [CapturedInvoice]) {
        Task { @MainActor in
            await refreshUnsyncedState(for: invoices)

            autoSyncTask?.cancel()
            autoSyncTask = nil

            guard hasValidatedDriveSession,
                  state == .linked,
                  !invoices.isEmpty,
                  !unsyncedInvoiceIDs.isEmpty else { return }

            autoSyncTask = Task(priority: .background) {
                let qualityRaw = UserDefaults.standard.string(forKey: Self.imageQualityPreferenceKey) ?? InvoiceImageQuality.large.rawValue
                let quality = InvoiceImageQuality(rawValue: qualityRaw) ?? .large

                var delay: UInt64 = 1_000_000_000
                let maximumDelay: UInt64 = 60_000_000_000

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                    guard await MainActor.run(body: { self.state == .linked && self.hasValidatedDriveSession }) else { return }

                    do {
                        _ = try await self.syncNow(quality: quality)
                        await MainActor.run { self.syncStatusRefresh() }
                        return
                    } catch {
                        if let syncError = error as? GoogleDriveSyncCoordinator.SyncError,
                           case .missingUserIdentity = syncError {
                            return
                        }
                        DriveConnectorLog.error("Auto-sync attempt failed: \(error.localizedDescription). Retrying with backoff.")
                        delay = min(delay * 2, maximumDelay)
                    }
                }
            }
        }
    }

    /// Attempts to unlink Drive. Returns `false` when unsynced invoices require confirmation.
    func unlinkAccount(force: Bool) async -> Bool {
        if hasUnsyncedInvoices && !force {
            DriveConnectorLog.info("Unlink requested but unsynced invoices present.")
            return false
        }

        if force && hasUnsyncedInvoices {
            let ids = Array(unsyncedInvoiceIDs)
            DriveConnectorLog.info("Removing \(ids.count) unsynced invoices prior to unlink.")
            removeInvoices(ids)
        }

        autoSyncTask?.cancel()
        autoSyncTask = nil
        clearLocalInvoices()
        await tracker.reset()
        transferService.disconnect()
        resetStateAfterDisconnect()
        DriveConnectorLog.info("Google Drive unlinked and local data cleared.")
        return true
    }
}

// MARK: - Private helpers

private extension GoogleDriveConnector {
    func resetStateAfterDisconnect() {
        state = .signedOut
        accountDisplayName = nil
        linkIssueMessage = nil
        hasUnsyncedInvoices = false
        unsyncedInvoiceIDs.removeAll()
        lastSyncSummary = nil
        hasValidatedDriveSession = false
        syncStatusRefresh()
    }

    func performStartupHealthCheck() async {
        let result = await transferService.performHealthCheck()
        DriveConnectorLog.debug("Startup health check result: \(result)")
        applyHealthCheckResult(result)

        if result == .linked {
            hasValidatedDriveSession = true
            await refreshUnsyncedState()
            syncStatusRefresh()
            await remoteFetcher?()
            await refreshUnsyncedState()
            syncStatusRefresh()
            await scheduleInitialSync()
        } else {
            hasValidatedDriveSession = false
            await tracker.reset()
        }
    }

    func applyHealthCheckResult(_ result: GoogleDriveAuthorizationState) {
        state = result
        switch result {
        case .linked:
            accountDisplayName = transferService.currentAccountName
            linkIssueMessage = nil
            hasValidatedDriveSession = true
            DriveConnectorLog.info("Session restored for \(accountDisplayName ?? transferService.currentUserID ?? "unknown user").")
        case .signedOut:
            accountDisplayName = nil
            let message = (transferService as? GoogleDriveTransferService)?.lastErrorDescription ??
            "Google Drive link expired. Please relink."
            linkIssueMessage = message
            DriveConnectorLog.error("Health check reported signed out: \(message)")
            unsyncedInvoiceIDs.removeAll()
            hasUnsyncedInvoices = false
            lastSyncSummary = nil
            hasValidatedDriveSession = false
        case .failed:
            accountDisplayName = nil
            let message = (transferService as? GoogleDriveTransferService)?.lastErrorDescription ??
            "Could not verify Google Drive. Check your network and try again."
            linkIssueMessage = message
            DriveConnectorLog.error("Health check failed: \(message)")
            unsyncedInvoiceIDs.removeAll()
            hasUnsyncedInvoices = false
            lastSyncSummary = nil
            hasValidatedDriveSession = false
        case .authorizing:
            break
        }
    }

    func refreshUnsyncedState(for invoices: [CapturedInvoice]? = nil) async {
        let invoicesToCheck = invoices ?? invoicesProvider()
        let syncedIDs = await tracker.syncedInvoiceIDs(for: invoicesToCheck)
        let unsynced = invoicesToCheck.filter { !syncedIDs.contains($0.id) }
        unsyncedInvoiceIDs = Set(unsynced.map(\.id))
        hasUnsyncedInvoices = !unsyncedInvoiceIDs.isEmpty
        DriveConnectorLog.debug("Unsynced invoices count: \(unsyncedInvoiceIDs.count)")
    }

    func scheduleInitialSync() async {
        guard hasValidatedDriveSession,
              state == .linked,
              !unsyncedInvoiceIDs.isEmpty else { return }
        let qualityRaw = UserDefaults.standard.string(forKey: Self.imageQualityPreferenceKey) ?? InvoiceImageQuality.large.rawValue
        let quality = InvoiceImageQuality(rawValue: qualityRaw) ?? .large
        let invoices = invoicesProvider()
        guard !invoices.isEmpty else { return }
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if state != .linked || Task.isCancelled { return }
            _ = try await syncNow(quality: quality)
        } catch {
            DriveConnectorLog.debug("Initial sync skipped or failed: \(error.localizedDescription)")
        }
    }
}
