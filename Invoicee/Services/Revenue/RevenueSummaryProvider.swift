import Foundation

@MainActor
protocol RevenueSummaryProviding: AnyObject {
    func totalRevenue(forMonth month: Int, year: Int) async -> Decimal?
}

/// Provides cached monthly revenue totals for the linked Drive account.
@MainActor
final class RevenueSummaryProvider: RevenueSummaryProviding {
    private let store: RevenueStoring
    private let driveConnector: GoogleDriveConnector
    private let calendar: Calendar

    init(store: RevenueStoring,
         driveConnector: GoogleDriveConnector,
         calendar: Calendar = .current) {
        self.store = store
        self.driveConnector = driveConnector
        self.calendar = calendar
    }

    func totalRevenue(forMonth month: Int, year: Int) async -> Decimal? {
        guard let userID = driveConnector.currentAccountID else { return nil }
        do {
            let entries = try await store.fetchEntries(for: userID)
            let totals = aggregate(entries: entries)
            return totals[cacheKey(month: month, year: year)]
        } catch {
            return nil
        }
    }

    private func aggregate(entries: [RevenueDayEntry]) -> [String: Decimal] {
        entries.reduce(into: [:]) { result, entry in
            let components = calendar.dateComponents([.year, .month], from: entry.date)
            guard let year = components.year, let month = components.month else { return }
            let key = cacheKey(month: month, year: year)
            let existing = result[key] ?? 0
            result[key] = existing + entry.total
        }
    }

    private func cacheKey(month: Int, year: Int) -> String {
        "\(year)-\(month)"
    }
}
