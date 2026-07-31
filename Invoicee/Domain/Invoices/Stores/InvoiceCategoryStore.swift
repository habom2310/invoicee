import Foundation
import Combine

/// Persists custom categories and supplier mappings in `UserDefaults`.
///
/// The published list is the union of categories derived from saved invoices and
/// categories the user typed in. Custom entries are persisted so they survive until the
/// invoice using them is saved (they used to vanish on the next archive change).
@MainActor
final class InvoiceCategoryStore: ObservableObject {
    @Published private(set) var categories: [String] = []
    @Published private(set) var supplierCategories: [String: String]

    private enum Key {
        static let supplierCategories = "invoiceSupplierCategories"
        static let customCategories = "invoiceCustomCategories"
    }

    private let userDefaults: UserDefaults
    private var derivedCategories: [String] = []
    private var customCategories: [String]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        supplierCategories = userDefaults.dictionary(forKey: Key.supplierCategories) as? [String: String] ?? [:]
        customCategories = userDefaults.stringArray(forKey: Key.customCategories) ?? []
        rebuildCategories()
    }

    func addCategory(_ rawValue: String) {
        guard let trimmed = rawValue.trimmed.nilIfEmpty,
              !customCategories.containsIgnoringCase(trimmed),
              !derivedCategories.containsIgnoringCase(trimmed) else { return }
        customCategories.append(trimmed)
        persistCustomCategories()
        rebuildCategories()
    }

    /// Refreshes the derived half of the list from the invoices currently stored.
    func updateCategories(from invoices: [CapturedInvoice]) {
        var derived: [String] = []
        for invoice in invoices {
            guard let category = invoice.category?.trimmed.nilIfEmpty,
                  !derived.containsIgnoringCase(category) else { continue }
            derived.append(category)
        }

        guard derived != derivedCategories else { return }
        derivedCategories = derived

        // Categories now backed by a saved invoice no longer need their own entry.
        let stillCustom = customCategories.filter { !derived.containsIgnoringCase($0) }
        if stillCustom != customCategories {
            customCategories = stillCustom
            persistCustomCategories()
        }
        rebuildCategories()
    }

    func category(for supplier: String) -> String? {
        Self.supplierKey(for: supplier).flatMap { supplierCategories[$0] }
    }

    /// Remembers `category` as this supplier's default, or forgets it when `category` is
    /// empty, so the next invoice from them pre-fills correctly.
    func rememberCategory(_ category: String?, for supplier: String) {
        guard let key = Self.supplierKey(for: supplier) else { return }

        let trimmed = category?.trimmed.nilIfEmpty
        guard supplierCategories[key] != trimmed else { return }

        if let trimmed {
            supplierCategories[key] = trimmed
        } else {
            supplierCategories.removeValue(forKey: key)
        }
        userDefaults.set(supplierCategories, forKey: Key.supplierCategories)
    }

    // MARK: - Private

    private func persistCustomCategories() {
        userDefaults.set(customCategories, forKey: Key.customCategories)
    }

    private func rebuildCategories() {
        var merged = derivedCategories
        for category in customCategories where !merged.containsIgnoringCase(category) {
            merged.append(category)
        }
        let sorted = merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard sorted != categories else { return }
        categories = sorted
    }

    /// Supplier names are matched case- and whitespace-insensitively, so "ACME " and
    /// "acme" share one remembered category.
    private static func supplierKey(for supplier: String) -> String? {
        supplier.trimmed.nilIfEmpty?.lowercased()
    }
}
