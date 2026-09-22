import Foundation
import Combine

/// Produces aggregated metrics for expenses by period, category, and supplier.
///
/// Aggregates are computed once per input change and published, rather than being
/// recomputed by each `body` pass that reads them.
@MainActor
final class ExpenseAnalyticsViewModel: ObservableObject {
    /// A name and the amount spent under it, plus that amount's share of the period and
    /// of revenue. Computed here so the views can render rows without doing arithmetic.
    struct Breakdown: Identifiable {
        let name: String
        let amount: Decimal
        let shareOfExpenses: Decimal
        let shareOfRevenue: Decimal?

        var id: String { name }
    }

    // MARK: - Published state

    @Published private(set) var invoices: [CapturedInvoice] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var monthlyRevenueTotal: Decimal?

    /// Invoices matching the current filter, newest first.
    @Published private(set) var invoicesForSelection: [CapturedInvoice] = []
    @Published private(set) var totalForSelection: Decimal = .zero
    @Published private(set) var totalGSTForSelection: Decimal = .zero
    @Published private(set) var categoryBreakdown: [Breakdown] = []
    @Published private(set) var supplierBreakdown: [Breakdown] = []

    @Published var selectedMetric: ExpenseMetric = .totalAmount {
        didSet {
            guard selectedMetric != oldValue else { return }
            recomputeAggregates()
            if !isApplyingExternalMetric {
                metricStore?.set(metric: selectedMetric)
            }
        }
    }

    /// The period on show, shared with the revenue and profit tabs.
    @Published var selection: ReportingPeriodSelection {
        didSet {
            guard selection != oldValue else { return }
            periodDidChange()
        }
    }

    // MARK: - Dependencies

    private let archive: InvoiceArchive
    private let calendar: Calendar
    private let periodStore: ReportingPeriodStore?
    private let metricStore: ExpenseMetricStore?
    private let revenueSummaryProvider: RevenueSummaryProviding?
    private var cancellables = Set<AnyCancellable>()
    private var revenueTask: Task<Void, Never>?
    private var isApplyingExternalSelection = false
    private var isApplyingExternalMetric = false

    /// - Parameters:
    ///   - archive: Source of captured invoices.
    ///   - calendar: Calendar used to derive reporting periods.
    ///   - periodStore: Optional shared selection store to keep views in sync.
    ///   - metricStore: Optional shared metric store to keep views in sync.
    ///   - revenueSummaryProvider: Supplies the monthly revenue used for expense ratios.
    init(archive: InvoiceArchive,
         calendar: Calendar = .current,
         periodStore: ReportingPeriodStore? = nil,
         metricStore: ExpenseMetricStore? = nil,
         revenueSummaryProvider: RevenueSummaryProviding? = nil) {
        self.archive = archive
        self.calendar = calendar
        self.periodStore = periodStore
        self.metricStore = metricStore
        self.revenueSummaryProvider = revenueSummaryProvider

        invoices = archive.invoices
        selection = periodStore?.selection ?? ReportingPeriodSelection(period: .day, calendar: calendar)
        if let metricStore {
            selectedMetric = metricStore.selectedMetric
        }

        recomputeAggregates()
        refreshRevenueTotal()
        observeArchive()
        observeStores()
        propagatePeriodChange()
    }

    deinit {
        revenueTask?.cancel()
    }

    // MARK: - Refreshing

    /// Re-reads the archive and the monthly revenue total.
    func refresh() async {
        errorMessage = nil
        applyInvoices(archive.invoices)
        revenueSummaryProvider?.invalidateCache()
        refreshRevenueTotal()
    }

    // MARK: - Derived display values

    var totalFormatted: String {
        totalForSelection.formattedCurrency()
    }

    var totalGSTFormatted: String {
        totalGSTForSelection.formattedCurrency()
    }

    var hasDataForSelection: Bool {
        !invoicesForSelection.isEmpty
    }

    /// `true` when a revenue figure exists to compare the period's spend against.
    var hasRevenueComparison: Bool {
        selection.period == .month && monthlyRevenueTotal != nil
    }

    /// The period's spend as a share of that month's revenue, e.g. "42% of revenue".
    var totalVsRevenueDescription: String? {
        guard selection.period == .month,
              let revenue = monthlyRevenueTotal,
              revenue > 0 else { return nil }
        return "\(Self.percentText(totalForSelection / revenue)) of revenue"
    }

    /// Formats a ratio, clamped to a range a display can hold. A mistyped invoice can
    /// otherwise produce a percentage thousands of digits wide.
    static func percentText(_ ratio: Decimal?) -> String {
        guard let ratio else { return "—" }
        let clamped = min(max(ratio.doubleValue, -999), 999)
        return clamped.formatted(.percent.precision(.fractionLength(0...1)))
    }

    // MARK: - Observation

    private func observeArchive() {
        archive.$invoices
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] invoices in
                self?.applyInvoices(invoices)
            }
            .store(in: &cancellables)
    }

    /// Mirrors the shared stores. Updates are delivered on the next run loop pass so a
    /// picker change never publishes back into the middle of a view update.
    private func observeStores() {
        if let periodStore {
            periodStore.$selection
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] selection in
                    self?.applyExternalSelection(selection)
                }
                .store(in: &cancellables)
        }

        if let metricStore {
            metricStore.$selectedMetric
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] metric in
                    self?.applyExternalMetric(metric)
                }
                .store(in: &cancellables)
        }
    }

    private func applyInvoices(_ invoices: [CapturedInvoice]) {
        self.invoices = invoices
        if !invoices.isEmpty {
            errorMessage = nil
        }
        recomputeAggregates()
    }

    private func applyExternalSelection(_ incoming: ReportingPeriodSelection) {
        guard selection != incoming else { return }
        isApplyingExternalSelection = true
        defer { isApplyingExternalSelection = false }
        selection = incoming
    }

    private func applyExternalMetric(_ metric: ExpenseMetric) {
        guard selectedMetric != metric else { return }
        isApplyingExternalMetric = true
        defer { isApplyingExternalMetric = false }
        selectedMetric = metric
    }

    // MARK: - Selection

    /// Runs after any period change: refreshes aggregates and mirrors the choice into
    /// the shared store.
    private func periodDidChange() {
        recomputeAggregates()
        propagatePeriodChange()
        refreshRevenueTotal()
    }

    private func propagatePeriodChange() {
        guard !isApplyingExternalSelection else { return }
        periodStore?.set(selection)
    }

    // MARK: - Aggregation

    private func recomputeAggregates() {
        let filtered = filteredInvoices()
        invoicesForSelection = filtered

        let metric = selectedMetric
        let periodTotal = filtered.reduce(Decimal.zero) { $0 + metric.value(in: $1) }
        totalForSelection = periodTotal
        totalGSTForSelection = filtered.reduce(.zero) { $0 + $1.gst }

        let revenueTotal = selection.period == .month ? monthlyRevenueTotal : nil
        categoryBreakdown = breakdown(of: filtered, periodTotal: periodTotal, revenueTotal: revenueTotal) {
            $0.category?.trimmed.nilIfEmpty ?? "Uncategorized"
        }
        supplierBreakdown = breakdown(of: filtered, periodTotal: periodTotal, revenueTotal: revenueTotal) {
            $0.supplier.trimmed.nilIfEmpty ?? "Unknown Supplier"
        }
    }

    private func filteredInvoices() -> [CapturedInvoice] {
        guard let range = selection.range else { return [] }
        return invoices
            .filter { calendar.isDay($0.date, in: range) }
            .sorted { $0.date > $1.date }
    }

    /// Totals `invoices` by key and turns each into a display row, ordered by descending
    /// amount then name. Zero-value groups are dropped: they carry no information and
    /// would divide into a meaningless 0% row.
    private func breakdown(of invoices: [CapturedInvoice],
                           periodTotal: Decimal,
                           revenueTotal: Decimal?,
                           by key: (CapturedInvoice) -> String) -> [Breakdown] {
        let metric = selectedMetric
        var totals: [String: Decimal] = [:]
        for invoice in invoices {
            totals[key(invoice), default: .zero] += metric.value(in: invoice)
        }

        // `nil` unless there is a positive revenue figure to divide by.
        let divisibleRevenue = (revenueTotal ?? .zero) > .zero ? revenueTotal : nil

        return totals
            .filter { $0.value > .zero }
            .sorted { lhs, rhs in
                lhs.value == rhs.value
                    ? lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                    : lhs.value > rhs.value
            }
            .map { entry in
                Breakdown(name: entry.key,
                          amount: entry.value,
                          shareOfExpenses: periodTotal > .zero ? entry.value / periodTotal : .zero,
                          shareOfRevenue: divisibleRevenue.map { entry.value / $0 })
            }
    }

    // MARK: - Revenue

    private func refreshRevenueTotal() {
        revenueTask?.cancel()

        guard selection.period == .month, let provider = revenueSummaryProvider else {
            guard monthlyRevenueTotal != nil else { return }
            monthlyRevenueTotal = nil
            recomputeAggregates()
            return
        }

        let month = selection.month
        let year = selection.year
        revenueTask = Task { [weak self] in
            let total = await provider.totalRevenue(forMonth: month, year: year)
            guard !Task.isCancelled, let self else { return }
            guard selection.month == month, selection.year == year, monthlyRevenueTotal != total else { return }
            monthlyRevenueTotal = total
            // The breakdown rows carry a revenue share, so they are stale now.
            recomputeAggregates()
        }
    }
}
