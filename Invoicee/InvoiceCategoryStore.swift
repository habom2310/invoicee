import Foundation
import Combine

final class InvoiceCategoryStore: ObservableObject {
    static let shared = InvoiceCategoryStore()

    @Published private(set) var categories: [String]

    private let storageKey = "invoiceCategories"

    private init() {
        if let saved = UserDefaults.standard.array(forKey: storageKey) as? [String] {
            categories = saved
        } else {
            categories = []
        }
    }

    func addCategory(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !categories.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            categories.append(trimmed)
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(categories, forKey: storageKey)
    }
}
