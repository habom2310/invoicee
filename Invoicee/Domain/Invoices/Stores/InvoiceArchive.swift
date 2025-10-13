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

    private let persistence: InvoicePersistence
    private let syncScheduler: InvoiceAutoSyncScheduling
    private let syncStatusProvider: InvoiceSyncStatusProvider

    init(persistence: InvoicePersistence,
         syncScheduler: InvoiceAutoSyncScheduling,
         syncStatusProvider: InvoiceSyncStatusProvider) {
        self.persistence = persistence
        self.syncScheduler = syncScheduler
        self.syncStatusProvider = syncStatusProvider

        let persistedInvoices = persistence.loadInvoices()
        invoices = persistedInvoices
        scheduleAutoSync(for: persistedInvoices)
        refreshSyncedState(for: persistedInvoices)
    }

    func update(with invoices: [CapturedInvoice]) {
        self.invoices = invoices
        persistence.saveInvoices(invoices)
        scheduleAutoSync(for: invoices)
        refreshSyncedState(for: invoices)
    }

    func refreshSyncStatus() {
        refreshSyncedState(for: invoices)
    }

    private func scheduleAutoSync(for invoices: [CapturedInvoice]) {
        syncScheduler.enqueueAutoSync(with: invoices)
    }

    private func refreshSyncedState(for invoices: [CapturedInvoice]) {
        Task {
            let synced = await syncStatusProvider.syncedInvoiceIDs(for: invoices)
            await MainActor.run {
                self.syncedInvoiceIDs = synced
            }
        }
    }
}
