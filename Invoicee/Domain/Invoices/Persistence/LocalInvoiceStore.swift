import Foundation

/// Persists invoices to disk using a JSON file inside Application Support.
struct LocalInvoiceStore: InvoicePersistence {
    private let fileManager: FileManager
    private let storageURL: URL
    private let encoderFactory: () -> JSONEncoder
    private let decoderFactory: () -> JSONDecoder

    init(fileManager: FileManager = .default,
         baseURL: URL? = nil,
         encoderFactory: @escaping () -> JSONEncoder = {
             let encoder = JSONEncoder()
             encoder.dateEncodingStrategy = .iso8601
             return encoder
         },
         decoderFactory: @escaping () -> JSONDecoder = {
             let decoder = JSONDecoder()
             decoder.dateDecodingStrategy = .iso8601
             return decoder
         }) {
        self.fileManager = fileManager
        self.encoderFactory = encoderFactory
        self.decoderFactory = decoderFactory
        storageURL = Self.makeStorageURL(fileManager: fileManager, baseURL: baseURL)
    }

    func loadInvoices() -> [CapturedInvoice] {
        guard fileManager.fileExists(atPath: storageURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = decoderFactory()
            return try decoder.decode([CapturedInvoice].self, from: data)
        } catch {
            print("LocalInvoiceStore load failed: \(error.localizedDescription)")
            return []
        }
    }

    func saveInvoices(_ invoices: [CapturedInvoice]) {
        let url = storageURL
        let encoder = encoderFactory()
        Task.detached(priority: .utility) {
            do {
                let data = try encoder.encode(invoices)
                try data.write(to: url, options: .atomic)
            } catch {
                print("LocalInvoiceStore save failed: \(error.localizedDescription)")
            }
        }
    }

    private static func makeStorageURL(fileManager: FileManager, baseURL: URL?) -> URL {
        let base = baseURL ??
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
        fileManager.temporaryDirectory

        let directory = base.appendingPathComponent("Invoicee", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("LocalInvoiceStore directory creation failed: \(error.localizedDescription)")
                return fileManager.temporaryDirectory.appendingPathComponent("invoicee-invoices.json")
            }
        }

        return directory.appendingPathComponent("invoices.json")
    }

}
