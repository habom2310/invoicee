import Foundation
import Combine

/// Aggregates revenue and expense data to produce profit insights.
@MainActor
final class ProfitAnalyticsViewModel: ObservableObject {
    /// Revenue and expense figures for one period, and the profit they imply.
    struct ProfitSummary: Equatable {
        var revenueGross: Decimal = .zero
        var expenseTotal: Decimal = .zero
        var expenseGST: Decimal = .zero

        /// Revenue less the GST it attracts.
        var revenueNet: Decimal {
            GSTRate.exclusiveNet(of: revenueGross)
        }

        /// Spend less the GST claimed back on it.
        var expenseNet: Decimal {
            expenseTotal - expenseGST
        }

        var profit: Decimal {
            revenueNet - expenseNet
        }

        var profitPercentage: Decimal? {
            guard revenueNet != .zero else { return nil }
            return profit / revenueNet
        }

        var isEmpty: Bool {
            revenueGross == .zero && expenseTotal == .zero
        }
    }

    /// A month's figures inside a yearly view.
    struct MonthlyBreakdown: Identifiable {
        let month: Int
        let year: Int
        let summary: ProfitSummary

        var id: Int { month }
    }

    @Published var selectedPeriod: ReportingPeriod = .week {
        didSet {
            guard selectedPeriod != oldValue else { return }
            recomputeMetrics()
        }
    }

    @Published var selectedMonth: Int {
        didSet {
            let clamped = min(max(selectedMonth, 1), 12)
            guard clamped == selectedMonth else {
                selectedMonth = clamped
                return
            }
            guard selectedMonth != oldValue else { return }
            recomputeMetrics()
        }
    }

    @Published var selectedYear: Int {
        didSet {
            guard selectedYear != oldValue else { return }
            recomputeMetrics()
        }
    }

    @Published private(set) var summary = ProfitSummary()
    @Published private(set) var monthlyBreakdown: [MonthlyBreakdown] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDriveLinked = false

    var hasAnyData: Bool {
        !invoices.isEmpty || !revenueEntries.isEmpty
    }

    var availableYears: [Int] {
        periodOptions.availableYears(including: selectedYear)
    }

    private let invoiceArchive: InvoiceArchive
    private let revenueStore: RevenueStoring
    private let driveConnector: GoogleDriveConnector
    private let metricStore: ExpenseMetricStore?
    private let calendar: Calendar
    private var cancellables: Set<AnyCancellable> = []
    private var invoices: [CapturedInvoice] = []
    private var revenueEntries: [RevenueDayEntry] = []
    private var selectedExpenseMetric: ExpenseMetric
    /// Rebuilt in `recomputeMetrics` rather than derived in `availableYears`, because the
    /// year menu reads that property from `body` on every pass.
    private var periodOptions: ReportingPeriodOptions

    init(invoiceArchive: InvoiceArchive,
         revenueStore: RevenueStoring,
         driveConnector: GoogleDriveConnector,
         metricStore: ExpenseMetricStore? = nil,
         calendar: Calendar = .current) {
        self.invoiceArchive = invoiceArchive
        self.revenueStore = revenueStore
        self.driveConnector = driveConnector
        self.metricStore = metricStore
        self.calendar = calendar
        selectedExpenseMetric = metricStore?.selectedMetric ?? .totalAmount
        periodOptions = ReportingPeriodOptions(dates: [], calendar: calendar)

        let today = calendar.startOfDay(for: Date())
        selectedMonth = calendar.component(.month, from: today)
        selectedYear = calendar.component(.year, from: today)

        invoices = invoiceArchive.invoices
        isDriveLinked = driveConnector.authorizationState() == .linked

        observeInvoices()
        observeDriveState()
        observeMetricStore()
        recomputeMetrics()
    }

    func refresh() async {
        guard !isLoading else { return }
        guard isDriveLinked, let identity = driveConnector.currentSyncIdentity else {
            // Expenses still summarise without Drive; only the revenue half is missing.
            revenueEntries = []
            errorMessage = Self.linkPromptMessage
            recomputeMetrics()
            return
        }

        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            recomputeMetrics()
        }

        do {
            revenueEntries = try await revenueStore.fetchEntries(for: identity)
                .map { RevenueDayEntry(documentID: $0.documentID,
                                       date: calendar.startOfDay(for: $0.date),
                                       streams: $0.streams) }
        } catch {
            errorMessage = error.userFacingDescription
            revenueEntries = []
        }
    }

    // MARK: - Display

    var summaryTitle: String {
        switch selectedPeriod {
        case .week: "This Week"
        case .month: "\(ReportingDateFormatter.name(for: selectedMonth)) \(selectedYear)"
        case .year: "\(selectedYear)"
        }
    }

    var summarySubtitle: String {
        switch selectedPeriod {
        case .week: weekRangeDescription ?? ""
        case .month: "Selected Month"
        case .year: "Calendar Year"
        }
    }

    var weekRangeDescription: String? {
        calendar.reportingWeek(containing: Date())?.description
    }

    var profitText: String {
        summary.profit.formattedCurrency()
    }

    var profitPercentageText: String? {
        Self.percentageText(summary.profitPercentage).map { "\($0) of revenue" }
    }

    var monthPickerLabel: String {
        "\(ReportingDateFormatter.name(for: selectedMonth)) \(selectedYear)"
    }

    var selectedDateRange: ReportingDateRange? {
        calendar.range(for: selectedPeriod, month: selectedMonth, year: selectedYear)
    }

    func monthName(for month: Int) -> String {
        ReportingDateFormatter.name(for: month)
    }

    static func percentageText(_ ratio: Decimal?) -> String? {
        guard let ratio else { return nil }
        return ratio.doubleValue.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private static let linkPromptMessage = "Link Google Drive to calculate profit."

    // MARK: - Observation

    // Each observer drops its first value: the current state is read directly in `init`,
    // so replaying it would duplicate the initial fetch and recompute.
    private func observeInvoices() {
        invoiceArchive.$invoices
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] invoices in
                guard let self else { return }
                self.invoices = invoices
                recomputeMetrics()
            }
            .store(in: &cancellables)
    }

    private func observeDriveState() {
        driveConnector.$state
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let linked = state == .linked
                guard linked != isDriveLinked else { return }
                isDriveLinked = linked

                if linked {
                    Task { await self.refresh() }
                } else {
                    revenueEntries = []
                    errorMessage = Self.linkPromptMessage
                    recomputeMetrics()
                }
            }
            .store(in: &cancellables)
    }

    private func observeMetricStore() {
        guard let metricStore else { return }
        metricStore.$selectedMetric
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] metric in
                guard let self else { return }
                selectedExpenseMetric = metric
                recomputeMetrics()
            }
            .store(in: &cancellables)
    }

    // MARK: - Aggregation

    private func recomputeMetrics() {
        // Both sides feed the year menu: an invoice-only year and a revenue-only year are
        // each worth offering.
        periodOptions = ReportingPeriodOptions(dates: invoices.map(\.date) + revenueEntries.map(\.date),
                                               calendar: calendar)
        summary = selectedDateRange.map(summary(for:)) ?? ProfitSummary()
        monthlyBreakdown = selectedPeriod == .year ? breakdown(forYear: selectedYear) : []
    }

    private func summary(for range: ReportingDateRange) -> ProfitSummary {
        var result = ProfitSummary(revenueGross: totalRevenue(in: range))
        for invoice in invoices where calendar.isDay(invoice.date, in: range) {
            result.expenseTotal += selectedExpenseMetric.value(in: invoice)
            result.expenseGST += invoice.gst
        }
        return result
    }

    private func breakdown(forYear year: Int) -> [MonthlyBreakdown] {
        (1...12).compactMap { month in
            guard let range = calendar.reportingMonth(month: month, year: year) else { return nil }
            let monthSummary = summary(for: range)
            guard !monthSummary.isEmpty else { return nil }
            return MonthlyBreakdown(month: month, year: year, summary: monthSummary)
        }
    }

    private func totalRevenue(in range: ReportingDateRange) -> Decimal {
        // Not `.lazy`: a single filter-and-reduce gains nothing from it, and `lazy.filter`
        // takes an *escaping* closure, which would need `self.calendar` here.
        revenueEntries.reduce(.zero) { total, entry in
            calendar.isDay(entry.date, in: range) ? total + entry.total : total
        }
    }
}
