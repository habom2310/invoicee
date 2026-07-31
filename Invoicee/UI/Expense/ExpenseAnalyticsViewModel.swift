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

    @Published var selectedPeriod: ReportingPeriod = .month {
        didSet {
            guard selectedPeriod != oldValue else { return }
            recomputeAggregates()
            propagatePeriodChange()
            refreshRevenueTotal()
        }
    }

    @Published var selectedYear: Int {
        didSet {
            guard selectedYear != oldValue else { return }
            periodDidChange()
        }
    }

    @Published var selectedMonth: Int {
        didSet {
            guard selectedMonth != oldValue else { return }
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
    private var isApplyingExternalPeriod = false
    private var isApplyingExternalMetric = false
    private var periodOptions: ReportingPeriodOptions

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

        let storedInvoices = archive.invoices
        let options = ReportingPeriodOptions(dates: storedInvoices.map(\.date), calendar: calendar)
        let clamped = options.clamped(month: periodStore?.selectedMonth ?? options.currentMonth,
                                      year: periodStore?.selectedYear ?? options.currentYear)

        invoices = storedInvoices
        periodOptions = options
        selectedMonth = clamped.month
        selectedYear = clamped.year
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

    var availableYears: [Int] {
        periodOptions.availableYears
    }

    var availableMonths: [Int] {
        periodOptions.availableMonths(for: selectedYear)
    }

    var weekRangeDescription: String? {
        calendar.reportingWeek(containing: Date())?.description
    }

    var monthPickerLabel: String {
        "\(ReportingDateFormatter.shortName(for: selectedMonth))-\(selectedYear)"
    }

    /// `true` when a revenue figure exists to compare the period's spend against.
    var hasRevenueComparison: Bool {
        selectedPeriod == .month && monthlyRevenueTotal != nil
    }

    /// The period's spend as a share of that month's revenue, e.g. "42% of revenue".
    var totalVsRevenueDescription: String? {
        guard selectedPeriod == .month,
              let revenue = monthlyRevenueTotal,
              revenue > 0 else { return nil }
        return "\(Self.percentText(totalForSelection / revenue)) of revenue"
    }

    var selectedPeriodDisplayTitle: String {
        switch selectedPeriod {
        case .week: "This Week"
        case .month: "\(ReportingDateFormatter.shortName(for: selectedMonth)) \(selectedYear)"
        case .year: "\(selectedYear)"
        }
    }

    var selectedPeriodDetailDescription: String {
        switch selectedPeriod {
        case .week: weekRangeDescription ?? "Current Week"
        case .month: "\(ReportingDateFormatter.name(for: selectedMonth)) \(selectedYear)"
        case .year: "Calendar Year"
        }
    }

    var selectedPeriodSentence: String {
        switch selectedPeriod {
        case .week: "this week"
        case .month: "\(ReportingDateFormatter.shortName(for: selectedMonth)) \(selectedYear)"
        case .year: "the year \(selectedYear)"
        }
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
            Publishers.CombineLatest(periodStore.$selectedMonth, periodStore.$selectedYear)
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] month, year in
                    self?.applyExternalPeriod(month: month, year: year)
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
        periodOptions = ReportingPeriodOptions(dates: invoices.map(\.date), calendar: calendar)
        // `clampSelection` re-enters `periodDidChange` and recomputes when it moves the
        // selection, so only recompute here when it left the selection alone.
        if !clampSelection() {
            recomputeAggregates()
        }
    }

    private func applyExternalPeriod(month: Int, year: Int) {
        guard selectedMonth != month || selectedYear != year else { return }
        isApplyingExternalPeriod = true
        defer { isApplyingExternalPeriod = false }
        // Month first: setting the year alone can leave the old month unselectable for
        // the new year and trigger a clamp that the incoming month would have satisfied.
        selectedMonth = month
        selectedYear = year
    }

    private func applyExternalMetric(_ metric: ExpenseMetric) {
        guard selectedMetric != metric else { return }
        isApplyingExternalMetric = true
        defer { isApplyingExternalMetric = false }
        selectedMetric = metric
    }

    // MARK: - Selection

    /// Runs after any month/year change: clamps to a selectable period, refreshes
    /// aggregates, and mirrors the choice into the shared store.
    private func periodDidChange() {
        guard !clampSelection() else { return }
        recomputeAggregates()
        propagatePeriodChange()
        refreshRevenueTotal()
    }

    /// Moves the selection onto an available period.
    /// - Returns: `true` when a value was changed, which re-enters `periodDidChange`.
    @discardableResult
    private func clampSelection() -> Bool {
        let clamped = periodOptions.clamped(month: selectedMonth, year: selectedYear)
        guard clamped.month != selectedMonth || clamped.year != selectedYear else { return false }
        selectedYear = clamped.year
        selectedMonth = clamped.month
        return true
    }

    private func propagatePeriodChange() {
        guard !isApplyingExternalPeriod, selectedPeriod == .month else { return }
        periodStore?.set(month: selectedMonth, year: selectedYear)
    }

    // MARK: - Aggregation

    private func recomputeAggregates() {
        let filtered = filteredInvoices()
        invoicesForSelection = filtered

        let metric = selectedMetric
        let periodTotal = filtered.reduce(Decimal.zero) { $0 + metric.value(in: $1) }
        totalForSelection = periodTotal
        totalGSTForSelection = filtered.reduce(.zero) { $0 + $1.gst }

        let revenueTotal = selectedPeriod == .month ? monthlyRevenueTotal : nil
        categoryBreakdown = breakdown(of: filtered, periodTotal: periodTotal, revenueTotal: revenueTotal) {
            $0.category?.trimmed.nilIfEmpty ?? "Uncategorized"
        }
        supplierBreakdown = breakdown(of: filtered, periodTotal: periodTotal, revenueTotal: revenueTotal) {
            $0.supplier.trimmed.nilIfEmpty ?? "Unknown Supplier"
        }
    }

    private func filteredInvoices() -> [CapturedInvoice] {
        guard let range = calendar.range(for: selectedPeriod, month: selectedMonth, year: selectedYear) else {
            return []
        }
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

        guard selectedPeriod == .month, let provider = revenueSummaryProvider else {
            guard monthlyRevenueTotal != nil else { return }
            monthlyRevenueTotal = nil
            recomputeAggregates()
            return
        }

        let month = selectedMonth
        let year = selectedYear
        revenueTask = Task { [weak self] in
            let total = await provider.totalRevenue(forMonth: month, year: year)
            guard !Task.isCancelled, let self else { return }
            guard selectedMonth == month, selectedYear == year, monthlyRevenueTotal != total else { return }
            monthlyRevenueTotal = total
            // The breakdown rows carry a revenue share, so they are stale now.
            recomputeAggregates()
        }
    }
}
