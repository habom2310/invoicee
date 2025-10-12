import Foundation
import Combine

@MainActor
final class ExpenseAnalyticsViewModel: ObservableObject {
    enum Metric: String, CaseIterable, Identifiable {
        case totalAmount
        case ourAmount

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .totalAmount: return "Total Amount"
            case .ourAmount: return "Our Amount"
            }
        }
    }

    struct CategoryTotal: Identifiable {
        let category: String
        let total: Decimal

        var id: String { category }
    }

    struct SupplierTotal: Identifiable {
        let supplier: String
        let total: Decimal

        var id: String { supplier }
    }

    @Published private(set) var invoices: [CapturedInvoice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedMetric: Metric = .totalAmount {
        didSet {
            updatePreviousMonthData()
        }
    }
    @Published var selectedYear: Int = Calendar.current.component(.year, from: Date()) {
        didSet {
            guard selectedYear != oldValue else { return }
            if selectedYear > currentYear {
                selectedYear = currentYear
                return
            }
            normalizeMonthForCurrentSelection()
            propagatePeriodChange()
        }
    }
    @Published var selectedMonth: Int = Calendar.current.component(.month, from: Date()) {
        didSet {
            guard selectedMonth != oldValue else { return }
            let allowedMonths = availableMonths(for: selectedYear)
            guard !allowedMonths.isEmpty else { return }
            if !allowedMonths.contains(selectedMonth) {
                if selectedYear == currentYear {
                    selectedMonth = allowedMonths.last ?? selectedMonth
                } else {
                    selectedMonth = allowedMonths.first ?? selectedMonth
                }
                return
            }
            updatePreviousMonthData()
            propagatePeriodChange()
        }
    }

    private let archive: InvoiceArchive
    private let calendar: Calendar
    private var cancellables = Set<AnyCancellable>()
    private let periodStore: ReportingPeriodStore?
    private var periodCancellable: AnyCancellable?
    private var isApplyingExternalPeriod = false

    @Published private(set) var previousMonthTotals: [CategoryTotal] = []
    @Published private(set) var previousMonthDescription: String? = nil

    init(archive: InvoiceArchive? = nil,
         calendar: Calendar = .current,
         periodStore: ReportingPeriodStore? = nil) {
        let resolvedArchive = archive ?? InvoiceArchive.shared
        self.archive = resolvedArchive
        self.calendar = calendar
        self.periodStore = periodStore

        if let store = periodStore {
            selectedYear = store.selectedYear
            selectedMonth = store.selectedMonth
        }

        resolvedArchive.$invoices
            .receive(on: RunLoop.main)
            .sink { [weak self] invoices in
                guard let self else { return }
                self.invoices = invoices
                if !invoices.isEmpty {
                    self.errorMessage = nil
                }
                self.updatePreviousMonthData()
                self.syncSelectionWithBounds()
            }
            .store(in: &cancellables)

        invoices = resolvedArchive.invoices
        updatePreviousMonthData()
        syncSelectionWithBounds()

        if let store = periodStore {
            observePeriodStore(store)
            propagatePeriodChange()
        }
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        await MainActor.run {
            invoices = archive.invoices
        }
        updatePreviousMonthData()
        syncSelectionWithBounds()
        isLoading = false
    }

    var totalForSelection: Decimal {
        filteredInvoices.reduce(.zero) { $0 + value(for: $1) }
    }

    var totalFormatted: String {
        totalForSelection.formattedCurrency()
    }

    var categoryTotals: [CategoryTotal] {
        let grouped = Dictionary(grouping: filteredInvoices) { invoice -> String in
            invoice.category ?? "Uncategorized"
        }

        let totals = grouped
            .map { key, invoices -> CategoryTotal in
                let total = invoices.reduce(Decimal.zero) { $0 + value(for: $1) }
                return CategoryTotal(category: key, total: total)
            }
            .sorted { lhs, rhs in
                if lhs.total == rhs.total {
                    return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
                }
                return lhs.total > rhs.total
            }
        return totals
    }

    var supplierTotals: [SupplierTotal] {
        let grouped = Dictionary(grouping: filteredInvoices) { invoice -> String in
            let name = invoice.supplier.trimmed
            return name.isEmpty ? "Unknown Supplier" : name
        }

        let totals = grouped
            .map { key, invoices -> SupplierTotal in
                let total = invoices.reduce(Decimal.zero) { $0 + value(for: $1) }
                return SupplierTotal(supplier: key, total: total)
            }
            .sorted { lhs, rhs in
                if lhs.total == rhs.total {
                    return lhs.supplier.localizedCaseInsensitiveCompare(rhs.supplier) == .orderedAscending
                }
                return lhs.total > rhs.total
            }
        return totals
    }

    var selectedPeriodDescription: String {
        "\(monthName(for: selectedMonth, short: true)) \(selectedYear)"
    }

    var selectedPeriodDescriptionFormatted: String {
        "\(monthName(for: selectedMonth, short: true))-\(selectedYear)"
    }

    var hasDataForSelection: Bool {
        !filteredInvoices.isEmpty
    }

    var availableYears: [Int] {
        var years = Set(invoices.map { calendar.component(.year, from: $0.date) })
        years.insert(currentYear)
        return years.filter { $0 <= currentYear }.sorted()
    }

    var availableMonths: [Int] {
        availableMonths(for: selectedYear)
    }

    func monthName(for month: Int, short: Bool = false) -> String {
        guard month >= 1 && month <= Self.monthSymbols.count else { return "Month" }
        return short ? Self.shortMonthSymbols[month - 1] : Self.monthSymbols[month - 1]
    }

    private var filteredInvoices: [CapturedInvoice] {
        invoices.filter { invoice in
            let components = calendar.dateComponents([.year, .month], from: invoice.date)
            return components.year == selectedYear && components.month == selectedMonth
        }
    }

    private func value(for invoice: CapturedInvoice) -> Decimal {
        switch selectedMetric {
        case .totalAmount:
            return invoice.total
        case .ourAmount:
            return invoice.ourAmount
        }
    }

    private func updatePreviousMonthData() {
        guard let previousComponents = previousMonthComponents,
              let month = previousComponents.month,
              let year = previousComponents.year else {
            previousMonthTotals = []
            previousMonthDescription = nil
            return
        }

        previousMonthDescription = "\(monthName(for: month, short: true)) \(year)"

        let previousInvoices = invoices.filter { invoice in
            let components = calendar.dateComponents([.year, .month], from: invoice.date)
            return components.year == year && components.month == month
        }

        let grouped = Dictionary(grouping: previousInvoices) { invoice -> String in
            invoice.category ?? "Uncategorized"
        }

        previousMonthTotals = grouped
            .map { key, invoices -> CategoryTotal in
                let total = invoices.reduce(Decimal.zero) { $0 + value(for: $1) }
                return CategoryTotal(category: key, total: total)
            }
            .sorted { lhs, rhs in
                if lhs.total == rhs.total {
                    return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
                }
                return lhs.total > rhs.total
            }
    }

    private func availableMonths(for year: Int) -> [Int] {
        var months = Set(invoices
            .filter { calendar.component(.year, from: $0.date) == year }
            .map { calendar.component(.month, from: $0.date) })

        if year == currentYear {
            months.formUnion(1...currentMonth)
        } else if year < currentYear {
            months.formUnion(1...12)
        }

        if months.isEmpty {
            if year == currentYear {
                months.formUnion(1...currentMonth)
            } else {
                months.formUnion(1...12)
            }
        }

        return months.sorted()
    }

    private func observePeriodStore(_ store: ReportingPeriodStore) {
        periodCancellable = Publishers.CombineLatest(store.$selectedMonth, store.$selectedYear)
            .receive(on: RunLoop.main)
            .sink { [weak self] month, year in
                self?.applyExternalPeriod(month: month, year: year)
            }
    }

    private func applyExternalPeriod(month: Int, year: Int) {
        guard selectedMonth != month || selectedYear != year else { return }
        isApplyingExternalPeriod = true
        selectedYear = year
        selectedMonth = month
        syncSelectionWithBounds()
        isApplyingExternalPeriod = false
        propagatePeriodChange()
    }

    private func propagatePeriodChange() {
        guard !isApplyingExternalPeriod else { return }
        periodStore?.set(month: selectedMonth, year: selectedYear)
    }

    private func syncSelectionWithBounds() {
        let years = availableYears
        if years.isEmpty {
            selectedYear = currentYear
            selectedMonth = min(selectedMonth, currentMonth)
            return
        }

        if !years.contains(selectedYear) {
            if let replacement = years.last, replacement != selectedYear {
                selectedYear = replacement
                return
            }
        }

        normalizeMonthForCurrentSelection()
    }

    private func normalizeMonthForCurrentSelection() {
        let months = availableMonths(for: selectedYear)
        guard !months.isEmpty else { return }

        if !months.contains(selectedMonth) {
            let replacement: Int
            if selectedYear == currentYear {
                replacement = months.last ?? currentMonth
            } else {
                replacement = months.first ?? selectedMonth
            }

            if selectedMonth != replacement {
                selectedMonth = replacement
            }
        }

        updatePreviousMonthData()
    }

    private var previousMonthComponents: DateComponents? {
        var components = DateComponents()
        components.year = selectedYear
        components.month = selectedMonth
        guard let currentDate = calendar.date(from: components),
              let previousDate = calendar.date(byAdding: .month, value: -1, to: currentDate) else {
            return nil
        }
        return calendar.dateComponents([.year, .month], from: previousDate)
    }

    private var currentYear: Int {
        calendar.component(.year, from: Date())
    }

    private var currentMonth: Int {
        calendar.component(.month, from: Date())
    }

    private static let monthSymbols: [String] = {
        let formatter = DateFormatter()
        return formatter.monthSymbols ?? []
    }()

    private static let shortMonthSymbols: [String] = {
        let formatter = DateFormatter()
        return formatter.shortMonthSymbols ?? []
    }()
}
