import Foundation
import Combine

protocol InvoicePersistence {
    func loadInvoices() -> [CapturedInvoice]
    func saveInvoices(_ invoices: [CapturedInvoice])
}

protocol InvoiceAutoSyncScheduling {
    func enqueueAutoSync(with invoices: [CapturedInvoice])
}

protocol InvoiceSyncStatusProvider {
    func syncedInvoiceIDs(for invoices: [CapturedInvoice]) async -> Set<UUID>
}

/// Owns the local list of captured invoices and coordinates persistence + sync.
@MainActor
final class InvoiceArchive: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    @Published private(set) var invoices: [CapturedInvoice]
    @Published private(set) var syncedInvoiceIDs: Set<UUID> = []

    private static let syncedIDsDefaultsKey = "invoicee.syncedInvoiceIDs"
    private let defaults: UserDefaults

    private let persistence: InvoicePersistence
    private let syncScheduler: InvoiceAutoSyncScheduling
    private let syncStatusProvider: InvoiceSyncStatusProvider

    init(persistence: InvoicePersistence,
         syncScheduler: InvoiceAutoSyncScheduling,
         syncStatusProvider: InvoiceSyncStatusProvider,
         defaults: UserDefaults = .standard) {
        self.persistence = persistence
        self.syncScheduler = syncScheduler
        self.syncStatusProvider = syncStatusProvider
        self.defaults = defaults

        let persistedInvoices = persistence.loadInvoices()
        invoices = persistedInvoices
        syncedInvoiceIDs = Self.loadSyncedIDs(from: defaults)
            .intersection(Set(persistedInvoices.map(\.id)))
        scheduleAutoSync(for: persistedInvoices)
        refreshSyncedState(for: persistedInvoices)
    }

    func update(with invoices: [CapturedInvoice]) {
        self.invoices = invoices
        syncedInvoiceIDs = syncedInvoiceIDs.intersection(Set(invoices.map(\.id)))
        persistSyncedIDs()
        persistence.saveInvoices(invoices)
        scheduleAutoSync(for: invoices)
        refreshSyncedState(for: invoices)
    }

    func refreshSyncStatus() {
        refreshSyncedState(for: invoices)
    }

    func markInvoicesSynced(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        syncedInvoiceIDs.formUnion(ids)
        persistSyncedIDs()
    }

    private func scheduleAutoSync(for invoices: [CapturedInvoice]) {
        syncScheduler.enqueueAutoSync(with: invoices)
    }

    private func refreshSyncedState(for invoices: [CapturedInvoice]) {
        Task {
            let synced = await syncStatusProvider.syncedInvoiceIDs(for: invoices)
            await MainActor.run {
                self.syncedInvoiceIDs = synced
                self.persistSyncedIDs()
            }
        }
    }

    private func persistSyncedIDs() {
        let ids = syncedInvoiceIDs.map(\.uuidString)
        defaults.set(ids, forKey: Self.syncedIDsDefaultsKey)
    }

    private static func loadSyncedIDs(from defaults: UserDefaults) -> Set<UUID> {
        guard let stored = defaults.array(forKey: syncedIDsDefaultsKey) as? [String] else {
            return []
        }
        let uuids = stored.compactMap(UUID.init)
        return Set(uuids)
    }
}
