import Foundation

/// How wide a span a reporting screen covers.
///
/// Every reporting tab offered the same choice through its own private enum
/// (`ExpenseAnalyticsViewModel.Filter`, `RevenueViewModel.SummaryFilter`,
/// `ProfitAnalyticsViewModel.Filter`) with identical cases and display names. One
/// shared type means the timeframe sheet, the range maths, and the export file naming
/// can never drift apart. `ReportingPeriodSelection` pairs one of these with the point
/// in time a screen is anchored to.
nonisolated enum ReportingPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    /// How the timeframe sheet names the period. Choosing one jumps to the period in
    /// progress, so the names are written from today's point of view.
    var timeframeName: String {
        switch self {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        }
    }

    /// The calendar unit one whole period spans, and so the step the revenue screen's
    /// back and forward controls take.
    var spanComponent: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// The step back to the span this period is measured against.
    ///
    /// A day is compared with the same weekday a week earlier rather than with
    /// yesterday: takings swing hard enough between weekdays that a Tuesday only means
    /// something against another Tuesday.
    var comparisonComponent: Calendar.Component {
        self == .day ? .weekOfYear : spanComponent
    }
}

nonisolated extension Calendar {
    /// The whole `period` that `date` falls inside.
    func range(for period: ReportingPeriod, containing date: Date) -> ReportingDateRange? {
        switch period {
        case .day: reportingDay(containing: date)
        case .week: reportingWeek(containing: date)
        case .month: reportingMonth(containing: date)
        case .year: reportingYear(containing: date)
        }
    }

    /// The span `range` is measured against: the period before it, covering only as much
    /// of itself as `range` has covered so far.
    ///
    /// A period still in progress is measured like for like - on a Wednesday, "this
    /// week" compares against last week up to *its* Wednesday. A period that has already
    /// finished compares against the whole of the one before it.
    ///
    /// Returns `nil` when `range` has not started yet.
    func precedingRange(for period: ReportingPeriod,
                        matching range: ReportingDateRange,
                        referenceDate: Date = .now) -> ReportingDateRange? {
        let today = startOfDay(for: referenceDate)
        guard today >= range.start,
              let shifted = date(byAdding: period.comparisonComponent, value: -1, to: range.start),
              let previous = self.range(for: period, containing: shifted) else {
            return nil
        }

        guard today < range.end else { return previous }

        // Still in progress: stop at the day of the earlier span that matches how far
        // this one has got. `Calendar` clamps a day the earlier period does not have, so
        // 31 March compares against all of February.
        guard let cutoff = date(byAdding: period.comparisonComponent, value: -1, to: today) else { return nil }
        return ReportingDateRange(start: previous.start,
                                  end: min(startOfDay(for: cutoff), previous.end))
    }
}
