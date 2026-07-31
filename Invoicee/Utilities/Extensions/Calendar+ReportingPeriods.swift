import Foundation

/// An inclusive range of whole days, used by every reporting screen.
nonisolated struct ReportingDateRange: Equatable {
    /// Start of the first day in the range.
    let start: Date
    /// Start of the last day in the range.
    let end: Date

    /// Localised "start – end" description.
    var description: String {
        "\(ReportingDateFormatter.mediumDate(start)) – \(ReportingDateFormatter.mediumDate(end))"
    }
}

nonisolated extension Calendar {
    /// The seven day range containing `date`, honouring the calendar's first weekday.
    func reportingWeek(containing date: Date) -> ReportingDateRange? {
        guard let interval = dateInterval(of: .weekOfYear, for: date) else { return nil }
        let start = startOfDay(for: interval.start)
        guard let end = self.date(byAdding: .day, value: 6, to: start) else { return nil }
        return ReportingDateRange(start: start, end: end)
    }

    /// The full calendar month, or `nil` when the month/year pair is not representable.
    func reportingMonth(month: Int, year: Int) -> ReportingDateRange? {
        guard let start = date(from: DateComponents(year: year, month: month, day: 1)),
              let dayCount = range(of: .day, in: .month, for: start)?.count,
              let end = date(byAdding: DateComponents(day: dayCount - 1), to: start) else {
            return nil
        }
        return ReportingDateRange(start: startOfDay(for: start), end: startOfDay(for: end))
    }

    /// The full calendar year, or `nil` when `year` is not representable.
    func reportingYear(_ year: Int) -> ReportingDateRange? {
        guard let start = date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return nil
        }
        return ReportingDateRange(start: startOfDay(for: start), end: startOfDay(for: end))
    }

    /// `true` when `date` falls inside `range`, comparing whole days.
    func isDay(_ date: Date, in range: ReportingDateRange) -> Bool {
        let day = startOfDay(for: date)
        return day >= range.start && day <= range.end
    }
}
