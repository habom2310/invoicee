import Foundation

@MainActor
protocol RevenueSummaryProviding: AnyObject {
    func totalRevenue(forMonth month: Int, year: Int) async -> Decimal?
    /// Drops any cached totals, e.g. after the user records revenue.
    func invalidateCache()
}

/// Provides cached monthly revenue totals for the linked Drive account.
///
/// Fetching is collection-wide, so results are cached and concurrent callers share a
/// single request instead of each hitting Firestore on every picker change.
@MainActor
final class RevenueSummaryProvider: RevenueSummaryProviding {
    private static let cacheLifetime: TimeInterval = 30

    private struct Cache {
        let identity: SyncIdentity
        let fetchedAt: Date
        let totals: [String: Decimal]

        func isValid(for identity: SyncIdentity, now: Date, lifetime: TimeInterval) -> Bool {
            self.identity == identity && now.timeIntervalSince(fetchedAt) < lifetime
        }
    }

    private let store: RevenueStoring
    private let driveConnector: GoogleDriveConnector
    private let calendar: Calendar
    private var cache: Cache?
    private var inFlight: (identity: SyncIdentity, task: Task<[String: Decimal]?, Never>)?

    init(store: RevenueStoring,
         driveConnector: GoogleDriveConnector,
         calendar: Calendar = .current) {
        self.store = store
        self.driveConnector = driveConnector
        self.calendar = calendar
    }

    func totalRevenue(forMonth month: Int, year: Int) async -> Decimal? {
        guard let identity = driveConnector.currentSyncIdentity else {
            invalidateCache()
            return nil
        }
        return await monthlyTotals(for: identity)?[Self.monthKey(month: month, year: year)]
    }

    func invalidateCache() {
        cache = nil
        // Also drop the in-flight request: it was started before whatever invalidated the
        // cache, so its result is already stale.
        inFlight?.task.cancel()
        inFlight = nil
    }

    private static func monthKey(month: Int, year: Int) -> String {
        "\(year)-\(month)"
    }

    private func monthlyTotals(for identity: SyncIdentity) async -> [String: Decimal]? {
        if let cache, cache.isValid(for: identity, now: Date(), lifetime: Self.cacheLifetime) {
            return cache.totals
        }

        if let inFlight, inFlight.identity == identity {
            return await inFlight.task.value
        }

        // A request for a different account is no longer wanted.
        inFlight?.task.cancel()

        let store = store
        let calendar = calendar
        let task = Task<[String: Decimal]?, Never> {
            guard let entries = try? await store.fetchEntries(for: identity) else { return nil }
            return entries.reduce(into: [String: Decimal]()) { result, entry in
                let components = calendar.dateComponents([.year, .month], from: entry.date)
                guard let year = components.year, let month = components.month else { return }
                result[Self.monthKey(month: month, year: year), default: .zero] += entry.total
            }
        }
        inFlight = (identity, task)

        let totals = await task.value
        // Only clear and cache if this task is still the current one; `invalidateCache`
        // may have replaced it while we awaited.
        guard inFlight?.task == task else { return totals }
        inFlight = nil
        if let totals {
            cache = Cache(identity: identity, fetchedAt: Date(), totals: totals)
        }
        return totals
    }
}
