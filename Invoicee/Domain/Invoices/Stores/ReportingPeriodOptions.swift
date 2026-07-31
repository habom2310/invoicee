import Foundation

/// Derives the month/year choices offered by the reporting pickers.
///
/// Shared by the invoice list and the expense analytics so both screens offer —
/// and clamp to — exactly the same set of periods.
struct ReportingPeriodOptions {
    private let calendar: Calendar
    private let invoiceYears: Set<Int>
    private let monthsByYear: [Int: Set<Int>]
    let currentMonth: Int
    let currentYear: Int

    init(dates: [Date], calendar: Calendar = .current, referenceDate: Date = Date()) {
        self.calendar = calendar
        currentMonth = calendar.component(.month, from: referenceDate)
        currentYear = calendar.component(.year, from: referenceDate)

        var years: Set<Int> = []
        var months: [Int: Set<Int>] = [:]
        for date in dates {
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { continue }
            years.insert(year)
            months[year, default: []].insert(month)
        }
        invoiceYears = years
        monthsByYear = months
    }

    /// Years that hold data, plus the current year, never in the future.
    var availableYears: [Int] {
        var years = invoiceYears.filter { $0 <= currentYear }
        years.insert(currentYear)
        return years.sorted()
    }

    /// Months selectable for `year`: every elapsed month, plus any month holding data.
    func availableMonths(for year: Int) -> [Int] {
        var months = monthsByYear[year] ?? []
        months.formUnion(year >= currentYear ? 1...currentMonth : 1...12)
        return months.sorted()
    }

    /// Clamps a month/year pair onto the available options.
    ///
    /// Out-of-range years fall back to the most recent available year; out-of-range
    /// months to the latest month of the current year, or the earliest of a past year.
    func clamped(month: Int, year: Int) -> (month: Int, year: Int) {
        let years = availableYears
        let resolvedYear = years.contains(year) ? year : (years.last ?? currentYear)

        let months = availableMonths(for: resolvedYear)
        guard !months.isEmpty else { return (month, resolvedYear) }
        guard !months.contains(month) else { return (month, resolvedYear) }

        let fallback = resolvedYear == currentYear ? months.last : months.first
        return (fallback ?? month, resolvedYear)
    }
}
