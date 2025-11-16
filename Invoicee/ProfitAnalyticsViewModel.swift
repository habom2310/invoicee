import Foundation
import Combine

/// Aggregates revenue and expense data to produce profit insights.
@MainActor
final class ProfitAnalyticsViewModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case week
        case month
        case year

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .week: return "Week"
            case .month: return "Month"
            case .year: return "Year"
            }
        }
    }

    struct ProfitSummary {
        var revenueGross: Decimal = .zero
        var revenueNet: Decimal = .zero
        var expenseTotal: Decimal = .zero
        var expenseGST: Decimal = .zero

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
    }

    struct MonthlyBreakdown: Identifiable {
        let month: Int
        let year: Int
        let revenueGross: Decimal
        let revenueNet: Decimal
        let expenseTotal: Decimal
        let expenseGST: Decimal

        var id: Int { month }

        var profit: Decimal {
            revenueNet - (expenseTotal - expenseGST)
        }

        var profitPercentage: Decimal? {
            guard revenueNet != .zero else { return nil }
            return profit / revenueNet
        }
    }

    @Published var selectedFilter: Filter = .week {
        didSet {
            guard selectedFilter != oldValue else { return }
            recomputeMetrics()
        }
    }
    @Published var selectedMonth: Int {
        didSet {
            guard selectedMonth != oldValue else { return }
            let clamped = clampMonth(selectedMonth)
            if clamped != selectedMonth {
                selectedMonth = clamped
                return
            }
            recomputeMetrics()
        }
    }
    @Published var selectedYear: Int {
        didSet {
            guard selectedYear != oldValue else { return }
            recomputeMetrics()
        }
    }
    @Published private(set) var summary: ProfitSummary = ProfitSummary()
    @Published private(set) var monthlyBreakdown: [MonthlyBreakdown] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDriveLinked = false

    var hasAnyData: Bool {
        !invoices.isEmpty || !revenueEntries.isEmpty
    }

    var availableYears: [Int] {
        var years = Set<Int>()
        years.formUnion(invoices.map { calendar.component(.year, from: $0.date) })
        years.formUnion(revenueEntries.map { calendar.component(.year, from: $0.date) })
        years.insert(calendar.component(.year, from: Date()))
        years.insert(selectedYear)
        return years.sorted()
    }

    let monthSymbols: [String]

    private let invoiceArchive: InvoiceArchive
    private let revenueStore: RevenueStoring
    private let driveConnector: GoogleDriveConnector
    private let calendar: Calendar
    private var cancellables: Set<AnyCancellable> = []
    private var invoices: [CapturedInvoice] = []
    private var revenueEntries: [RevenueDayEntry] = []
    private let netRevenueMultiplier = Decimal(9) / Decimal(10)

    init(invoiceArchive: InvoiceArchive,
         revenueStore: RevenueStoring,
         driveConnector: GoogleDriveConnector,
         calendar: Calendar = .current) {
        self.invoiceArchive = invoiceArchive
        self.revenueStore = revenueStore
        self.driveConnector = driveConnector
        self.calendar = calendar
        monthSymbols = ReportingDateFormatter.monthSymbols

        let today = calendar.startOfDay(for: Date())
        selectedMonth = calendar.component(.month, from: today)
        selectedYear = calendar.component(.year, from: today)

        invoices = invoiceArchive.invoices
        isDriveLinked = driveConnector.authorizationState() == .linked

        observeInvoices()
        observeDriveState()
        recomputeMetrics()
    }

    func refresh() async {
        guard isDriveLinked else { return }
        guard let userID = driveConnector.currentAccountID else {
            errorMessage = "Link Google Drive to calculate profit."
            revenueEntries = []
            recomputeMetrics()
            return
        }
        if isLoading { return }

        isLoading = true
        errorMessage = nil

        do {
            let fetched = try await revenueStore.fetchEntries(for: userID)
            revenueEntries = fetched
                .map { entry in
                    RevenueDayEntry(documentID: entry.documentID,
                                    date: calendar.startOfDay(for: entry.date),
                                    streams: entry.streams)
                }
                .sorted(by: { $0.date < $1.date })
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            revenueEntries = []
        }

        isLoading = false
        recomputeMetrics()
    }

    var summaryTitle: String {
        switch selectedFilter {
        case .week:
            return "This Week"
        case .month:
            return "\(monthName(for: selectedMonth)) \(selectedYear)"
        case .year:
            return "\(selectedYear)"
        }
    }

    var summarySubtitle: String {
        switch selectedFilter {
        case .week:
            return weekRangeDescription ?? ""
        case .month:
            return "Selected Month"
        case .year:
            return "Calendar Year"
        }
    }

    var weekRangeDescription: String? {
        guard let bounds = weekBounds(containing: Date()) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale.current
        return "\(formatter.string(from: bounds.start)) – \(formatter.string(from: bounds.end))"
    }

    var profitText: String {
        summary.profit.formattedCurrency()
    }

    var profitPercentageText: String? {
        guard let percentage = summary.profitPercentage else { return nil }
        let value = (percentage as NSDecimalNumber).doubleValue
        let formatted = value.formatted(.percent.precision(.fractionLength(0...1)))
        return "\(formatted) of revenue"
    }

    var monthPickerLabel: String {
        "\(monthName(for: selectedMonth)) \(selectedYear)"
    }

    func monthName(for month: Int) -> String {
        guard month >= 1, month <= monthSymbols.count else { return "Month" }
        return monthSymbols[month - 1]
    }

    func formattedPercentage(for breakdown: MonthlyBreakdown) -> String? {
        guard let ratio = breakdown.profitPercentage else { return nil }
        let value = (ratio as NSDecimalNumber).doubleValue
        let formatted = value.formatted(.percent.precision(.fractionLength(0...1)))
        return formatted
    }

    // MARK: - Private helpers

    private func observeInvoices() {
        invoiceArchive.$invoices
            .receive(on: RunLoop.main)
            .sink { [weak self] invoices in
                guard let self else { return }
                self.invoices = invoices
                self.recomputeMetrics()
            }
            .store(in: &cancellables)
    }

    private func observeDriveState() {
        driveConnector.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let linked = state == .linked
                isDriveLinked = linked
                if linked {
                    Task { await self.refresh() }
                } else {
                    revenueEntries = []
                    errorMessage = "Link Google Drive to calculate profit."
                    recomputeMetrics()
                }
            }
            .store(in: &cancellables)
    }

    private func recomputeMetrics() {
        summary = computeSummary()
        if selectedFilter == .year {
            monthlyBreakdown = computeBreakdownForYear(selectedYear)
        } else {
            monthlyBreakdown = []
        }
    }

    private func computeSummary() -> ProfitSummary {
        switch selectedFilter {
        case .week:
            guard let bounds = weekBounds(containing: Date()) else { return ProfitSummary() }
            return summary(for: bounds.start, end: bounds.end)
        case .month:
            guard let range = monthRange(month: selectedMonth, year: selectedYear) else { return ProfitSummary() }
            return summary(for: range.start, end: range.end)
        case .year:
            guard let range = yearRange(year: selectedYear) else { return ProfitSummary() }
            return summary(for: range.start, end: range.end)
        }
    }

    private func summary(for start: Date, end: Date) -> ProfitSummary {
        let revenueGross = totalRevenue(from: start, to: end)
        let expenseTotals = totalExpenses(from: start, to: end)
        return ProfitSummary(revenueGross: revenueGross,
                             revenueNet: revenueGross * netRevenueMultiplier,
                             expenseTotal: expenseTotals.total,
                             expenseGST: expenseTotals.gst)
    }

    private func computeBreakdownForYear(_ year: Int) -> [MonthlyBreakdown] {
        (1...12).compactMap { month in
            guard let range = monthRange(month: month, year: year) else { return nil }
            let revenueTotal = totalRevenue(from: range.start, to: range.end)
            let expenseTotals = totalExpenses(from: range.start, to: range.end)
            if revenueTotal == .zero && expenseTotals.total == .zero {
                return nil
            }
            return MonthlyBreakdown(month: month,
                                    year: year,
                                    revenueGross: revenueTotal,
                                    revenueNet: revenueTotal * netRevenueMultiplier,
                                    expenseTotal: expenseTotals.total,
                                    expenseGST: expenseTotals.gst)
        }
        .sorted(by: { $0.month < $1.month })
    }

    private func totalRevenue(from start: Date, to end: Date) -> Decimal {
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: end)
        return revenueEntries.reduce(into: Decimal.zero) { partialResult, entry in
            if entry.date >= normalizedStart && entry.date <= normalizedEnd {
                partialResult += entry.total
            }
        }
    }

    private func totalExpenses(from start: Date, to end: Date) -> (total: Decimal, gst: Decimal) {
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: end)
        var total: Decimal = .zero
        var gst: Decimal = .zero
        for invoice in invoices {
            let day = calendar.startOfDay(for: invoice.date)
            guard day >= normalizedStart && day <= normalizedEnd else { continue }
            total += invoice.total
            gst += invoice.gst
        }
        return (total, gst)
    }

    private func weekBounds(containing date: Date) -> (start: Date, end: Date)? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return nil }
        let start = calendar.startOfDay(for: interval.start)
        guard let end = calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
        return (start, end)
    }

    private func monthRange(month: Int, year: Int) -> (start: Date, end: Date)? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: start),
              let end = calendar.date(byAdding: DateComponents(day: range.count - 1), to: start) else {
            return nil
        }
        return (calendar.startOfDay(for: start), calendar.startOfDay(for: end))
    }

    private func yearRange(year: Int) -> (start: Date, end: Date)? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return nil
        }
        return (calendar.startOfDay(for: start), calendar.startOfDay(for: end))
    }

    private func clampMonth(_ value: Int) -> Int {
        max(1, min(12, value))
    }
}
