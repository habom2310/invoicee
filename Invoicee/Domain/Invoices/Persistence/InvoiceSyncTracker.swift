import Foundation

/// Tracks which invoices have been successfully synchronised with remote storage.
actor InvoiceSyncTracker: InvoiceSyncStatusProvider {
    struct Record: Codable {
        let lastEdited: Date
        let imagePath: String?
        let pdfPath: String?
    }

    private let storageKey: String
    /// `UserDefaults` is thread-safe, so it is shared across isolation domains.
    nonisolated(unsafe) private let userDefaults: UserDefaults
    private var records: [UUID: Record]

    init(userDefaults: UserDefaults = .standard, storageKey: String = "invoiceSyncedRecords") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        if let data = userDefaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        } else {
            records = [:]
        }
    }

    func record(for id: UUID) -> Record? {
        records[id]
    }

    func isUpToDate(_ invoice: CapturedInvoice) -> Bool {
        guard let record = records[invoice.id] else { return false }
        return record.lastEdited >= invoice.lastEdited
    }

    func markSynced(invoice: CapturedInvoice, imagePath: String?, pdfPath: String? = nil) {
        records[invoice.id] = Record(lastEdited: invoice.lastEdited, imagePath: imagePath, pdfPath: pdfPath)
        persist()
    }

    func removeRecord(for id: UUID) {
        guard records.removeValue(forKey: id) != nil else { return }
        persist()
    }

    /// Highest upload increment seen per base file name, so new uploads keep counting up.
    func highestIncrementLookup() -> [String: Int] {
        var lookup: [String: Int] = [:]
        for record in records.values {
            for path in [record.imagePath, record.pdfPath] {
                guard let path, let parsed = DriveUploadMetadata.parseFileName(from: path) else { continue }
                lookup[parsed.baseName] = max(lookup[parsed.baseName] ?? 0, parsed.increment)
            }
        }
        return lookup
    }

    func reset() {
        guard !records.isEmpty else { return }
        records.removeAll()
        persist()
    }

    func syncedInvoiceIDs(for invoices: [CapturedInvoice]) async -> Set<UUID> {
        Set(invoices.lazy.filter(isUpToDate).map(\.id))
    }

    private func persist() {
        let stringKeyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stringKeyed) {
            userDefaults.set(data, forKey: storageKey)
        } else {
            userDefaults.removeObject(forKey: storageKey)
        }
    }
}
