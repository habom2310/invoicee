import Foundation

/// A reporting screen's period, and the span of days it covers.
///
/// All three reporting tabs navigate the same way - choose a timeframe, then step
/// through spans one at a time - so the arithmetic, the titles, and the export file name
/// fragment live here instead of three times over.
///
/// `range` is stored rather than derived: a custom span is the user's own dates, and
/// there is no anchor arithmetic that would produce it.
nonisolated struct ReportingPeriodSelection: Equatable {
    let period: ReportingPeriod
    let range: ReportingDateRange

    private let calendar: Calendar

    init(period: ReportingPeriod, containing date: Date = .now, calendar: Calendar = .current) {
        self.period = period
        self.calendar = calendar
        let day = calendar.startOfDay(for: date)
        range = calendar.range(for: period, containing: day) ?? ReportingDateRange(start: day, end: day)
    }

    /// A span the user picked outright.
    init(custom range: ReportingDateRange, calendar: Calendar = .current) {
        period = .custom
        self.calendar = calendar
        self.range = ReportingDateRange(start: calendar.startOfDay(for: range.start),
                                        end: calendar.startOfDay(for: max(range.start, range.end)))
    }

    // MARK: - Spans

    /// The first day of the span. Pinning a preset here is what stops a run of backward
    /// steps from drifting off a 31st onto a 28th and staying there.
    var anchor: Date { range.start }

    /// Whole days the span covers, counting both ends.
    var dayCount: Int {
        (calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0) + 1
    }

    /// The span this one is measured against. See `Calendar.precedingRange(for:matching:)`.
    func precedingRange(referenceDate: Date = .now) -> ReportingDateRange? {
        calendar.precedingRange(for: period, matching: range, referenceDate: referenceDate)
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
        case .custom: range.description
        }
    }

    /// The exact span, for the screens that spell it out beneath their total. `nil` when
    /// `title` already is the span.
    var rangeDescription: String? {
        guard period != .day, period != .custom else { return nil }
        return range.description
    }

    /// Names the span a comparison is measured against, e.g. "vs. Prior Tuesday".
    var comparisonLabel: String {
        switch period {
        case .day: "vs. Prior \(ReportingDateFormatter.weekdayName(anchor))"
        case .week: "vs. Prior week"
        case .month: "vs. Prior month"
        case .year: "vs. Prior year"
        case .custom: dayCount == 1 ? "vs. Prior day" : "vs. Prior \(dayCount) days"
        }
    }

    /// This span's fragment of an export file name.
    var exportIdentifier: String {
        switch period {
        case .day: ReportingDateFormatter.fileNameDay(anchor)
        case .week: ReportingDateFormatter.weekIdentifier(range)
        case .month: ReportingDateFormatter.monthIdentifier(month: month, year: year)
        case .year: String(year)
        case .custom:
            range.start == range.end
                ? ReportingDateFormatter.fileNameDay(range.start)
                : "\(ReportingDateFormatter.fileNameDay(range.start))_\(ReportingDateFormatter.fileNameDay(range.end))"
        }
    }

    // MARK: - Navigation

    /// Forward travel stops at the span in progress: nothing can be recorded past today.
    func canStepForward(referenceDate: Date = .now) -> Bool {
        range.end < calendar.startOfDay(for: referenceDate)
    }

    /// One whole span back (`-1`) or forward (`+1`).
    func stepped(by delta: Int) -> Self {
        // A preset re-derives its range from the moved anchor, which keeps month lengths
        // honest. A custom span has no such rule, so both ends move by its own length.
        guard period.isCustom else {
            guard let shifted = calendar.date(byAdding: period.spanComponent, value: delta, to: anchor) else {
                return self
            }
            return Self(period: period, containing: shifted, calendar: calendar)
        }

        let days = delta * dayCount
        guard let start = calendar.date(byAdding: .day, value: days, to: range.start),
              let end = calendar.date(byAdding: .day, value: days, to: range.end) else {
            return self
        }
        return Self(custom: ReportingDateRange(start: start, end: end), calendar: calendar)
    }

    /// Switches timeframe and jumps to the span in progress, which is what the timeframe
    /// sheet's "Today"/"This week" wording promises. Choosing `custom` keeps the dates
    /// already picked, since only the editor sets those.
    func selecting(_ period: ReportingPeriod, referenceDate: Date = .now) -> Self {
        guard period.isCustom else {
            return Self(period: period, containing: referenceDate, calendar: calendar)
        }
        guard !self.period.isCustom else { return self }
        return Self(custom: range, calendar: calendar)
    }

    /// Applies the dates the custom editor produced.
    func selectingCustom(_ range: ReportingDateRange) -> Self {
        Self(custom: range, calendar: calendar)
    }

    /// Re-anchors onto a month without changing the timeframe.
    func anchored(month: Int, year: Int) -> Self {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return self
        }
        return Self(period: period, containing: date, calendar: calendar)
    }
}
