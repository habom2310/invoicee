import Foundation
import Combine

/// Central coordinator for Drive authentication, manual sync, and archive hygiene.
@MainActor
final class GoogleDriveConnector: ObservableObject, InvoiceAutoSyncScheduling {
    static let imageQualityPreferenceKey = "invoiceImageQualityPreference"

    private enum Timing {
        /// Grace period before touching the network on launch, so the first frames render
        /// and a just-resumed app has connectivity back.
        static let startupDelay: Duration = .seconds(5)
        /// Debounce between an invoice change and the auto-sync that follows it.
        static let autoSyncDebounce: Duration = .seconds(1)
        static let autoSyncMaximumBackoff: Duration = .seconds(60)
        static let autoSyncMaximumAttempts = 5
        static let initialSyncDelay: Duration = .seconds(2)
    }

    enum ConnectorError: LocalizedError {
        case notLinked

        var errorDescription: String? {
            switch self {
            case .notLinked: "Link Google Drive before syncing."
            }
        }
    }

    @Published private(set) var state: GoogleDriveAuthorizationState
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var linkIssueMessage: String?
    @Published private(set) var hasUnsyncedInvoices = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncSummary: String?

    /// The upload size the user picked in settings.
    var imageQuality: InvoiceImageQuality {
        get {
            InvoiceImageQuality(rawValue: defaults.string(forKey: Self.imageQualityPreferenceKey) ?? "") ?? .large
        }
        set {
            guard newValue != imageQuality else { return }
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.imageQualityPreferenceKey)
        }
    }

    /// What the Firestore-backed screens key their reads and writes on.
    ///
    /// Deliberately the only account identifier this connector exposes: the Google
    /// account ID it replaced is asserted by this app rather than verified by Firebase,
    /// so a caller reaching for it to decide what data to show would be trusting the
    /// wrong half of `SyncIdentity`.
    var currentSyncIdentity: SyncIdentity? {
        transferService.currentSyncIdentity
    }

    let transferService: CloudStorageTransferService

    /// Set once, after construction, because the host owns the archive this connector
    /// syncs and the host in turn needs the connector to ask whether Drive is linked.
    weak var host: InvoiceSyncHost?

    private let syncCoordinator: GoogleDriveSyncCoordinating
    private let tracker: InvoiceSyncTracker
    private let defaults: UserDefaults

    private var hasValidatedDriveSession = false
    private var autoSyncTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var unsyncedInvoiceIDs: Set<UUID> = []

    init(transferService: CloudStorageTransferService,
         syncCoordinator: GoogleDriveSyncCoordinating,
         tracker: InvoiceSyncTracker,
         defaults: UserDefaults = .standard) {
        self.transferService = transferService
        self.syncCoordinator = syncCoordinator
        self.tracker = tracker
        self.defaults = defaults
        state = transferService.currentAuthorizationState()
        accountDisplayName = transferService.currentAccountName
        AppLog.driveConnector.debug("Connector initialised. State: \(state)")
        scheduleHealthCheck()
    }

    deinit {
        autoSyncTask?.cancel()
        healthCheckTask?.cancel()
    }

    func authorizationState() -> GoogleDriveAuthorizationState {
        state
    }

    func refreshLinkState() {
        scheduleHealthCheck()
    }

    /// Launches the Google auth flow and persists the resulting session.
    func linkAccount() async {
        guard state != .authorizing else { return }

        state = .authorizing
        linkIssueMessage = nil
        AppLog.driveConnector.info("Starting Google Drive sign-in.")

        do {
            try await transferService.authorize()
            try await transferService.ensureRootFolder()
            state = .linked
            accountDisplayName = transferService.currentAccountName
            linkIssueMessage = nil
            hasValidatedDriveSession = true
            AppLog.driveConnector.info("Google Drive linked for \(accountDescription).")
            await reconcileAfterLink()
        } catch {
            state = .failed
            let message = transferService.failureDescription(for: error)
            AppLog.driveConnector.error("Google Drive link failed: \(message)")
            clearLinkedState(message: message)
        }
    }

    /// Performs a manual synchronization of invoices + Firebase metadata.
    /// - Returns: how many invoices were uploaded, or `0` when there was nothing to do.
    @discardableResult
    func syncNow(quality: InvoiceImageQuality? = nil) async throws -> Int {
        guard state == .linked else {
            AppLog.driveConnector.error("Sync requested while Drive not linked.")
            throw ConnectorError.notLinked
        }

        guard !isSyncing else {
            AppLog.driveConnector.debug("Sync requested while another sync is running; ignoring.")
            return 0
        }

        isSyncing = true
        lastSyncSummary = "Syncing…"
        defer { isSyncing = false }

        do {
            let invoices = host?.invoicesToSync ?? []
            let outcome = try await syncCoordinator.syncInvoices(invoices, quality: quality ?? imageQuality)
            await refreshUnsyncedState(for: invoices)
            host?.refreshSyncStatus()

            lastSyncSummary = outcome.count == 0
                ? "All invoices already synced."
                : "Synced \(outcome.count) invoice\(outcome.count == 1 ? "" : "s")."
            AppLog.driveConnector.info(lastSyncSummary ?? "Sync completed.")
            return outcome.count
        } catch {
            lastSyncSummary = nil
            AppLog.driveConnector.error("Manual sync failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Records that invoices changed; recalculates the unsynced set and schedules a sync.
    func enqueueAutoSync(with invoices: [CapturedInvoice]) {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            guard let self else { return }
            await refreshUnsyncedState(for: invoices)
            guard !Task.isCancelled else { return }
            await runAutoSyncIfNeeded()
        }
    }

    /// Attempts to unlink Drive.
    /// - Returns: `false` when unsynced invoices require confirmation, so the caller can
    ///   ask the user before discarding them.
    @discardableResult
    func unlinkAccount(force: Bool) async -> Bool {
        guard force || !hasUnsyncedInvoices else {
            AppLog.driveConnector.info("Unlink requested but unsynced invoices present.")
            return false
        }

        autoSyncTask?.cancel()
        autoSyncTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil

        // Every local invoice goes, unsynced or not: without a linked account there is
        // nowhere for the attachments to live.
        host?.removeAllInvoices()
        await tracker.reset()
        transferService.disconnect()

        state = .signedOut
        clearLinkedState(message: nil)
        host?.refreshSyncStatus()
        AppLog.driveConnector.info("Google Drive unlinked and local data cleared.")
        return true
    }
}

// MARK: - Private helpers

private extension GoogleDriveConnector {
    var accountDescription: String {
        accountDisplayName ?? transferService.currentUserID ?? "unknown user"
    }

    /// Verifies the stored session after a short delay, then reconciles sync state.
    func scheduleHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            try? await Task.sleep(for: Timing.startupDelay)
            guard !Task.isCancelled else { return }
            await self?.performStartupHealthCheck()
        }
    }

    func performStartupHealthCheck() async {
        let result = await transferService.performHealthCheck()
        AppLog.driveConnector.debug("Startup health check result: \(result)")
        applyHealthCheckResult(result)

        guard result == .linked else {
            // The tracker's records describe uploads for an account we can no longer
            // reach, so they would wrongly mark invoices as already synced.
            await tracker.reset()
            host?.refreshSyncStatus()
            return
        }

        await reconcileAfterLink()
        await scheduleInitialSync()
    }

    /// Pulls remote invoices in, then recomputes what still needs uploading.
    func reconcileAfterLink() async {
        await refreshUnsyncedState()
        host?.refreshSyncStatus()
        await host?.fetchRemoteInvoices()
        await refreshUnsyncedState()
        host?.refreshSyncStatus()
    }

    func applyHealthCheckResult(_ result: GoogleDriveAuthorizationState) {
        state = result
        switch result {
        case .linked:
            accountDisplayName = transferService.currentAccountName
            linkIssueMessage = nil
            hasValidatedDriveSession = true
            AppLog.driveConnector.info("Session restored for \(accountDescription).")
        case .signedOut, .failed:
            let fallback = result == .signedOut
                ? "Google Drive link expired. Please relink."
                : "Could not verify Google Drive. Check your network and try again."
            let message = transferService.lastFailureDescription ?? fallback
            AppLog.driveConnector.error("Health check reported \(result): \(message)")
            clearLinkedState(message: message)
        case .authorizing:
            break
        }
    }

    /// Forgets everything that only makes sense while an account is linked.
    func clearLinkedState(message: String?) {
        accountDisplayName = nil
        linkIssueMessage = message
        unsyncedInvoiceIDs.removeAll()
        hasUnsyncedInvoices = false
        lastSyncSummary = nil
        hasValidatedDriveSession = false
    }

    func refreshUnsyncedState(for invoices: [CapturedInvoice]? = nil) async {
        let invoicesToCheck = invoices ?? host?.invoicesToSync ?? []
        let syncedIDs = await tracker.syncedInvoiceIDs(for: invoicesToCheck)
        unsyncedInvoiceIDs = Set(invoicesToCheck.lazy.map(\.id).filter { !syncedIDs.contains($0) })
        hasUnsyncedInvoices = !unsyncedInvoiceIDs.isEmpty
        AppLog.driveConnector.debug("Unsynced invoices count: \(unsyncedInvoiceIDs.count)")
    }

    var canAutoSync: Bool {
        hasValidatedDriveSession && state == .linked && !unsyncedInvoiceIDs.isEmpty
    }

    /// Retries the pending upload with exponential backoff, giving up after a bounded
    /// number of attempts instead of looping for the lifetime of the app.
    ///
    /// Runs inline on the caller's task so cancelling `autoSyncTask` cancels the retry
    /// loop too — a detached retry chain used to outlive the change that started it.
    func runAutoSyncIfNeeded() async {
        guard canAutoSync else { return }

        var delay = Timing.autoSyncDebounce
        for attempt in 1...Timing.autoSyncMaximumAttempts {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return // Cancelled: a newer change is already scheduling its own sync.
            }

            // A manual sync already covers the pending invoices.
            guard canAutoSync, !isSyncing else { return }

            do {
                _ = try await syncNow()
                host?.refreshSyncStatus()
                return
            } catch is GoogleDriveSyncCoordinator.SyncError {
                return
            } catch is ConnectorError {
                return
            } catch {
                AppLog.driveConnector.error("Auto-sync attempt \(attempt) failed: \(error.localizedDescription). Retrying with backoff.")
                delay = min(delay * 2, Timing.autoSyncMaximumBackoff)
            }
        }
        AppLog.driveConnector.error("Auto-sync gave up after \(Timing.autoSyncMaximumAttempts) attempts.")
    }

    func scheduleInitialSync() async {
        guard canAutoSync else { return }
        do {
            try await Task.sleep(for: Timing.initialSyncDelay)
            guard state == .linked else { return }
            _ = try await syncNow()
        } catch {
            AppLog.driveConnector.debug("Initial sync skipped or failed: \(error.localizedDescription)")
        }
    }
}
