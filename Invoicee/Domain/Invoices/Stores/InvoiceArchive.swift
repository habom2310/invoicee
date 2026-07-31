import Foundation
import Combine

@MainActor
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
///
/// This is the single source of truth for invoices: views read `invoices` and mutate
/// through `upsert`/`remove` rather than keeping their own copies.
@MainActor
final class InvoiceArchive: ObservableObject {
    @Published private(set) var invoices: [CapturedInvoice]
    /// Which invoices are known to be uploaded. Derived from `syncStatusProvider` — the
    /// sync tracker is the only thing that decides this, so it is never stored here.
    @Published private(set) var syncedInvoiceIDs: Set<UUID> = []

    private let persistence: InvoicePersistence
    private let syncScheduler: InvoiceAutoSyncScheduling
    private let syncStatusProvider: InvoiceSyncStatusProvider
    private var syncStatusTask: Task<Void, Never>?

    init(persistence: InvoicePersistence,
         syncScheduler: InvoiceAutoSyncScheduling,
         syncStatusProvider: InvoiceSyncStatusProvider) {
        self.persistence = persistence
        self.syncScheduler = syncScheduler
        self.syncStatusProvider = syncStatusProvider

        let persisted = persistence.loadInvoices()
        invoices = persisted
        syncScheduler.enqueueAutoSync(with: persisted)
        refreshSyncedState(for: persisted)
    }

    deinit {
        syncStatusTask?.cancel()
    }

    // MARK: - Reading

    func invoice(with id: UUID) -> CapturedInvoice? {
        invoices.first { $0.id == id }
    }

    // MARK: - Mutating

    /// Replaces the whole archive, e.g. after a remote merge.
    func update(with invoices: [CapturedInvoice]) {
        guard invoices != self.invoices else { return }
        apply(invoices)
    }

    /// Inserts a new invoice, or replaces the stored copy of an existing one.
    func upsert(_ invoice: CapturedInvoice) {
        var updated = invoices
        if let index = updated.firstIndex(where: { $0.id == invoice.id }) {
            guard updated[index] != invoice else { return }
            updated[index] = invoice
        } else {
            updated.insert(invoice, at: 0)
        }
        apply(updated)
    }

    func remove(id: UUID) {
        let remaining = invoices.filter { $0.id != id }
        guard remaining.count != invoices.count else { return }
        apply(remaining)
    }

    func removeAll() {
        guard !invoices.isEmpty else { return }
        apply([])
    }

    // MARK: - Sync bookkeeping

    func refreshSyncStatus() {
        refreshSyncedState(for: invoices)
    }

    // MARK: - Private

    private func apply(_ invoices: [CapturedInvoice]) {
        self.invoices = invoices
        // Drop IDs that no longer exist immediately; the refresh below settles the rest.
        syncedInvoiceIDs.formIntersection(invoices.lazy.map(\.id))
        persistence.saveInvoices(invoices)
        syncScheduler.enqueueAutoSync(with: invoices)
        refreshSyncedState(for: invoices)
    }

    private func refreshSyncedState(for invoices: [CapturedInvoice]) {
        syncStatusTask?.cancel()
        syncStatusTask = Task { [weak self, syncStatusProvider] in
            let synced = await syncStatusProvider.syncedInvoiceIDs(for: invoices)
            guard !Task.isCancelled, let self, synced != syncedInvoiceIDs else { return }
            syncedInvoiceIDs = synced
        }
    }
}
