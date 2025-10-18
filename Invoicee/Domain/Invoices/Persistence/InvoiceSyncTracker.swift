import Foundation

/// Tracks which invoices have been successfully synchronised with remote storage.
actor InvoiceSyncTracker: InvoiceSyncStatusProvider {
    struct Record: Codable {
        let lastEdited: Date
        let imagePath: String?
        let pdfPath: String?
    }

    private let storageKey: String
    nonisolated(unsafe) private let userDefaults: UserDefaults
    private var records: [UUID: Record]

    init(userDefaults: UserDefaults = .standard, storageKey: String = "invoiceSyncedRecords") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        if let data = userDefaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
            let mapped = stored.compactMap { (key, value) -> (UUID, Record)? in
                guard let uuid = UUID(uuidString: key) else { return nil }
                return (uuid, value)
            }
            records = Dictionary(uniqueKeysWithValues: mapped)
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
        records.removeValue(forKey: id)
        persist()
    }

    func highestIncrementLookup() -> [String: Int] {
        var lookup: [String: Int] = [:]
        for record in records.values {
            if let path = record.imagePath,
               let parsed = parseAttachmentPath(path) {
                let current = lookup[parsed.baseName] ?? 0
                lookup[parsed.baseName] = max(current, parsed.increment)
            }
            if let path = record.pdfPath,
               let parsed = parseAttachmentPath(path) {
                let current = lookup[parsed.baseName] ?? 0
                lookup[parsed.baseName] = max(current, parsed.increment)
            }
        }
        return lookup
    }

    func reset() {
        records.removeAll()
        persist()
    }

    func syncedInvoiceIDs(for invoices: [CapturedInvoice]) async -> Set<UUID> {
        var result: Set<UUID> = []
        for invoice in invoices {
            if isUpToDate(invoice) {
                result.insert(invoice.id)
            }
        }
        return result
    }

    private func persist() {
        let stringKeyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        let defaults = userDefaults
        Task { @MainActor [defaults] in
            if let data = try? JSONEncoder().encode(stringKeyed) {
                defaults.set(data, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }
    }

    private func parseAttachmentPath(_ path: String) -> DriveUploadMetadata.ParsedFileName? {
        let fileNameWithExtension = path.split(separator: "/").last.map(String.init) ?? path
        let fileName: String
        if let dotIndex = fileNameWithExtension.lastIndex(of: ".") {
            fileName = String(fileNameWithExtension[..<dotIndex])
        } else {
            fileName = fileNameWithExtension
        }

        let components = fileName.split(separator: "_")
        guard components.count >= 4 else { return nil }

        var imageNumber: Int? = nil
        var incrementComponentIndex = components.count - 1
        let lastComponent = components[incrementComponentIndex]

        if lastComponent.hasPrefix("image") {
            let suffix = lastComponent.dropFirst("image".count)
            guard let value = Int(suffix) else { return nil }
            imageNumber = value
            incrementComponentIndex -= 1
        }

        guard incrementComponentIndex >= 0,
              let incrementValue = Int(components[incrementComponentIndex]) else { return nil }

        let baseComponents = components[..<incrementComponentIndex]
        guard !baseComponents.isEmpty else { return nil }
        let baseName = baseComponents.joined(separator: "_")

        return DriveUploadMetadata.ParsedFileName(baseName: baseName, increment: incrementValue, imageNumber: imageNumber)
    }
}
