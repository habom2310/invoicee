import SwiftUI
import Combine
import Foundation

extension Color {
    static var invoiceBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
#elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
#else
        Color.gray.opacity(0.08)
#endif
    }
}

extension Binding where Value == String {
    func enforcingNumeric(allowDecimal: Bool) -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue.filteredNumeric(allowDecimal: allowDecimal)
            }
        )
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func filteredNumeric(allowDecimal: Bool) -> String {
        var result = ""
        var hasDecimalSeparator = false

        for character in self {
            if character.isNumber {
                result.append(character)
            } else if allowDecimal && character == "." && !hasDecimalSeparator {
                hasDecimalSeparator = true
                result.append(character)
            }
        }

        return result
    }
}

extension NumberFormatter {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()
}

extension Decimal {
    init?(string: String) {
        self.init(string: string, locale: Locale(identifier: "en_US_POSIX"))
    }

    func formattedCurrency() -> String {
        NumberFormatter.currency.string(from: NSDecimalNumber(decimal: self)) ?? ""
    }

    var plainString: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}

enum GSTValidator {
    private static let maximumPercentage = Decimal(string: "0.10")!

    static func sanitizedAmount(for gst: Decimal?, total: Decimal?) -> Decimal? {
        guard let gst else { return nil }
        guard let total, total > 0 else { return gst }

        let maximumAllowed = total * maximumPercentage
        return gst >= maximumAllowed ? nil : gst
    }
}

extension Date {
    func formattedInvoiceDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy"
        return formatter.string(from: self)
    }
}

@MainActor
final class InvoiceArchive: ObservableObject {
    static let shared = InvoiceArchive()

    @Published private(set) var invoices: [CapturedInvoice] = []
    @Published private(set) var syncedInvoiceIDs: Set<UUID> = []

    private let storageURL: URL

    private init() {
        storageURL = Self.makeStorageURL()
        let persistedInvoices = Self.loadInvoices(from: storageURL)
        invoices = persistedInvoices
        scheduleAutoSync(for: persistedInvoices)
        refreshSyncedState(for: persistedInvoices)
    }

    func update(with invoices: [CapturedInvoice]) {
        self.invoices = invoices
        persist(invoices)
        scheduleAutoSync(for: invoices)
        refreshSyncedState(for: invoices)
    }

    func refreshSyncStatus() {
        refreshSyncedState(for: invoices)
    }

    private func scheduleAutoSync(for invoices: [CapturedInvoice]) {
        GoogleDriveConnector.shared.enqueueAutoSync(with: invoices)
    }

    private func refreshSyncedState(for invoices: [CapturedInvoice]) {
        Task {
            var synced: Set<UUID> = []
            let tracker = InvoiceSyncTracker.shared
            for invoice in invoices {
                if await tracker.isUpToDate(invoice) {
                    synced.insert(invoice.id)
                }
            }
            await MainActor.run {
                self.syncedInvoiceIDs = synced
            }
        }
    }

    private func persist(_ invoices: [CapturedInvoice]) {
        let url = storageURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(invoices)
                try data.write(to: url, options: .atomic)
            } catch {
                print("InvoiceArchive persistence failed: \(error.localizedDescription)")
            }
        }
    }

    private static func makeStorageURL() -> URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent("Invoicee", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("InvoiceArchive directory creation failed: \(error.localizedDescription)")
                return fileManager.temporaryDirectory.appendingPathComponent("invoicee-invoices.json")
            }
        }

        return directory.appendingPathComponent("invoices.json")
    }

    private static func loadInvoices(from url: URL) -> [CapturedInvoice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CapturedInvoice].self, from: data)
        } catch {
            print("InvoiceArchive load failed: \(error.localizedDescription)")
            return []
        }
    }
}
