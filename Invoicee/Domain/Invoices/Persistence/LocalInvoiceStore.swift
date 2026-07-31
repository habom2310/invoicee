import Foundation

/// Persists invoices to disk using a JSON file inside Application Support.
///
/// Writes are handed to a serial actor and tagged with the order they were requested in,
/// so a slow encode can never overwrite a newer snapshot.
@MainActor
final class LocalInvoiceStore: InvoicePersistence {
    private let fileManager: FileManager
    private let storageURL: URL
    private let writer: InvoiceFileWriter
    private var nextSequence = 0

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        storageURL = Self.makeStorageURL(fileManager: fileManager, baseURL: baseURL)
        writer = InvoiceFileWriter(url: storageURL)
    }

    func loadInvoices() -> [CapturedInvoice] {
        guard fileManager.fileExists(atPath: storageURL.path) else { return [] }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CapturedInvoice].self, from: Data(contentsOf: storageURL))
        } catch {
            AppLog.store.error("Load failed: \(error.localizedDescription)")
            return []
        }
    }

    func saveInvoices(_ invoices: [CapturedInvoice]) {
        nextSequence += 1
        let sequence = nextSequence
        let writer = writer
        Task.detached(priority: .utility) {
            await writer.write(invoices, sequence: sequence)
        }
    }

    private static func makeStorageURL(fileManager: FileManager, baseURL: URL?) -> URL {
        let base = baseURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let directory = base.appendingPathComponent("Invoicee", isDirectory: true)

        do {
            // `withIntermediateDirectories` makes this a no-op when it already exists, so
            // there is no need to check first.
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            AppLog.store.error("Directory creation failed: \(error.localizedDescription)")
            return fileManager.temporaryDirectory.appendingPathComponent("invoicee-invoices.json")
        }

        return directory.appendingPathComponent("invoices.json")
    }
}

/// Serializes invoice writes and discards snapshots that a newer write superseded.
private actor InvoiceFileWriter {
    private let url: URL
    private var lastWrittenSequence = 0

    init(url: URL) {
        self.url = url
    }

    func write(_ invoices: [CapturedInvoice], sequence: Int) {
        guard sequence > lastWrittenSequence else { return }
        lastWrittenSequence = sequence

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(invoices).write(to: url, options: .atomic)
        } catch {
            AppLog.store.error("Save failed: \(error.localizedDescription)")
        }
    }
}
