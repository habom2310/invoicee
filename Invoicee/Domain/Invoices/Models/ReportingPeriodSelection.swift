import Foundation

/// A reporting screen's period, and the point in time it is anchored to.
///
/// All three reporting tabs navigate the same way - choose a timeframe, then step
/// through periods one at a time - so the anchor arithmetic, the titles, and the export
/// file name fragment live here instead of three times over.
nonisolated struct ReportingPeriodSelection: Equatable {
    let period: ReportingPeriod
    /// Always the first day of `period`. Pinning it there is what stops a run of
    /// backward steps from drifting off a 31st onto a 28th and staying there.
    let anchor: Date

    private let calendar: Calendar

    init(period: ReportingPeriod, containing date: Date = .now, calendar: Calendar = .current) {
        self.period = period
        self.calendar = calendar
        let day = calendar.startOfDay(for: date)
        anchor = calendar.range(for: period, containing: day)?.start ?? day
    }

    // MARK: - Spans

    /// The span on show.
    var range: ReportingDateRange? {
        calendar.range(for: period, containing: anchor)
    }

    /// The span this one is measured against. See `Calendar.precedingRange(for:matching:)`.
    func precedingRange(referenceDate: Date = .now) -> ReportingDateRange? {
        guard let range else { return nil }
        return calendar.precedingRange(for: period, matching: range, referenceDate: referenceDate)
    }

    var month: Int { calendar.component(.month, from: anchor) }
    var year: Int { calendar.component(.year, from: anchor) }

    // MARK: - Display

    /// How the period control names what is on show, e.g. "Week of 21 Sep 2026".
    var title: String {
        switch period {
        case .day: ReportingDateFormatter.mediumDate(anchor)
        case .week: "Week of \(ReportingDateFormatter.mediumDate(anchor))"
        case .month: ReportingDateFormatter.monthAndYear(anchor)
        case .year: String(year)
        }
    }

    /// The exact span, for the screens that spell it out beneath their total. `nil` for a
    /// single day, where it would only repeat `title`.
    var rangeDescription: String? {
        guard period != .day else { return nil }
        return range?.description
    }

    /// Names the span a comparison is measured against, e.g. "vs. Prior Tuesday".
    var comparisonLabel: String {
        switch period {
        case .day: "vs. Prior \(ReportingDateFormatter.weekdayName(anchor))"
        case .week: "vs. Prior week"
        case .month: "vs. Prior month"
        case .year: "vs. Prior year"
        }
    }

    /// This period's fragment of an export file name.
    var exportIdentifier: String {
        switch period {
        case .day: ReportingDateFormatter.fileNameDay(anchor)
        case .week: ReportingDateFormatter.weekIdentifier(range)
        case .month: ReportingDateFormatter.monthIdentifier(month: month, year: year)
        case .year: String(year)
        }
    }

    // MARK: - Navigation

    /// Forward travel stops at the period in progress: nothing can be recorded past today.
    func canStepForward(referenceDate: Date = .now) -> Bool {
        guard let range else { return false }
        return range.end < calendar.startOfDay(for: referenceDate)
    }

    /// One whole period back (`-1`) or forward (`+1`).
    func stepped(by delta: Int) -> Self {
        guard let shifted = calendar.date(byAdding: period.spanComponent, value: delta, to: anchor) else {
            return self
        }
        return Self(period: period, containing: shifted, calendar: calendar)
    }

    /// Switches timeframe and jumps to the period in progress, which is what the
    /// timeframe sheet's "Today"/"This week" wording promises.
    func selecting(_ period: ReportingPeriod, referenceDate: Date = .now) -> Self {
        Self(period: period, containing: referenceDate, calendar: calendar)
    }

    /// Re-anchors onto a month without changing the timeframe, for the shared month/year
    /// store the invoice list writes to.
    func anchored(month: Int, year: Int) -> Self {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return self
        }
        return Self(period: period, containing: date, calendar: calendar)
    }
}
