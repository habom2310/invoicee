import Foundation
import Combine

/// Persists custom categories and supplier mappings in `UserDefaults`.
final class InvoiceCategoryStore: ObservableObject {
    @Published private(set) var categories: [String]
    @Published private(set) var supplierCategories: [String: String]

    private let userDefaults: UserDefaults
    private let supplierCategoryStorageKey = "invoiceSupplierCategories"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        categories = []

        if let savedMap = userDefaults.dictionary(forKey: supplierCategoryStorageKey) as? [String: String] {
            supplierCategories = savedMap
        } else {
            supplierCategories = [:]
        }
    }

    func addCategory(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !categories.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            categories.append(trimmed)
            sortCategories()
        }
    }

    func category(for supplier: String) -> String? {
        guard let key = normalizedSupplierKey(for: supplier) else { return nil }
        return supplierCategories[key]
    }

    func rememberCategory(_ category: String?, for supplier: String) {
        guard let key = normalizedSupplierKey(for: supplier) else { return }

        guard let category else {
            supplierCategories.removeValue(forKey: key)
            saveSupplierCategories()
            return
        }

        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategory.isEmpty else {
            supplierCategories.removeValue(forKey: key)
            saveSupplierCategories()
            return
        }

        supplierCategories[key] = trimmedCategory
        saveSupplierCategories()
    }

    private func normalizedSupplierKey(for supplier: String) -> String? {
        let trimmed = supplier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private func saveSupplierCategories() {
        userDefaults.set(supplierCategories, forKey: supplierCategoryStorageKey)
    }

    private func sortCategories() {
        categories.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func updateCategories(from invoices: [CapturedInvoice]) {
        var derived: [String] = []
        for invoice in invoices {
            guard let category = invoice.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !category.isEmpty else { continue }
            if !derived.contains(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) {
                derived.append(category)
            }
        }

        categories = derived.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
