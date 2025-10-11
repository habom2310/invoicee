import Foundation
import Combine

final class InvoiceCategoryStore: ObservableObject {
    static let shared = InvoiceCategoryStore()

    @Published private(set) var categories: [String]
    @Published private(set) var supplierCategories: [String: String]

    private let storageKey = "invoiceCategories"
    private let supplierCategoryStorageKey = "invoiceSupplierCategories"

    private init() {
        if let saved = UserDefaults.standard.array(forKey: storageKey) as? [String] {
            categories = saved
        } else {
            categories = []
        }

        if let savedMap = UserDefaults.standard.dictionary(forKey: supplierCategoryStorageKey) as? [String: String] {
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
            saveCategories()
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

    private func saveCategories() {
        UserDefaults.standard.set(categories, forKey: storageKey)
    }

    private func saveSupplierCategories() {
        UserDefaults.standard.set(supplierCategories, forKey: supplierCategoryStorageKey)
    }
}
