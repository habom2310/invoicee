internal import SwiftUI

/// A month grid for picking a span of days in one pass.
///
/// One tap sets the start, the next completes the span, and a tap after that starts over
/// from the day tapped. There is no separate start and end field: the bar drawn across
/// the grid *is* the answer.
struct CalendarRangePicker: View {
    @Binding var range: ReportingDateRange

    private let calendar: Calendar
    private let today: Date
    /// Set while a start is chosen but the span is unfinished, so the next tap ends it.
    @State private var pendingStart: Date?
    @State private var visibleMonth: Date

    private static let cellHeight: CGFloat = 44
    private static let markDiameter: CGFloat = 36

    init(range: Binding<ReportingDateRange>, calendar: Calendar = .current) {
        _range = range
        self.calendar = calendar
        today = calendar.startOfDay(for: Date())
        // Open on the month the span ends in - the end is the one nearer today when a
        // preset as wide as a year was carried in.
        _visibleMonth = State(initialValue: calendar.startOfMonth(for: range.wrappedValue.end))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            weekdayHeader
            grid
        }
    }

    private var header: some View {
        HStack {
            Text(ReportingDateFormatter.monthAndYear(visibleMonth))
                .font(.title2.weight(.bold))
            Spacer()
            monthButton(systemImage: "arrow.left", value: -1, enabled: true, label: "Previous month")
            monthButton(systemImage: "arrow.right", value: 1, enabled: canGoForward, label: "Next month")
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: Self.cellHeight)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDay(day, in: range)
        let isStart = calendar.isDate(day, inSameDayAs: range.start)
        let isEnd = calendar.isDate(day, inSameDayAs: range.end)
        let isEndpoint = isSelected && (isStart || isEnd)
        let isSelectable = day <= today

        Button {
            select(day)
        } label: {
            ZStack {
                // Two halves rather than one rectangle, so the bar stops at the middle of
                // the first and last day and reads as joining the two marks.
                HStack(spacing: 0) {
                    half(filled: isSelected && !isStart)
                    half(filled: isSelected && !isEnd)
                }

                if isEndpoint {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: Self.markDiameter, height: Self.markDiameter)
                } else if calendar.isDateInToday(day) {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1)
                        .frame(width: Self.markDiameter, height: Self.markDiameter)
                }

                Text(dayNumber(day))
                    .font(.callout.weight(isEndpoint ? .semibold : .regular))
                    .foregroundStyle(numberColor(isEndpoint: isEndpoint, isSelectable: isSelectable))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .accessibilityLabel(ReportingDateFormatter.mediumDate(day))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func half(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? Color.accentColor.opacity(0.18) : Color.clear)
            .frame(height: Self.markDiameter)
            .frame(maxWidth: .infinity)
    }

    private func numberColor(isEndpoint: Bool, isSelectable: Bool) -> Color {
        if isEndpoint { return .white }
        return isSelectable ? .primary : Color.secondary.opacity(0.4)
    }

    private func monthButton(systemImage: String, value: Int, enabled: Bool, label: String) -> some View {
        Button {
            guard let moved = calendar.date(byAdding: .month, value: value, to: visibleMonth) else { return }
            visibleMonth = calendar.startOfMonth(for: moved)
        } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.bold))
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    // MARK: - Selection

    private func select(_ day: Date) {
        guard let start = pendingStart else {
            // Either nothing is chosen yet or a finished span is being replaced. Both
            // start over from this day, which is also what shows until the next tap.
            pendingStart = day
            range = ReportingDateRange(start: day, end: day)
            return
        }
        range = ReportingDateRange(start: min(start, day), end: max(start, day))
        pendingStart = nil
    }

    // MARK: - Grid maths

    private var canGoForward: Bool {
        visibleMonth < calendar.startOfMonth(for: today)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    /// The visible month laid out in rows of seven, padded with `nil` at both ends.
    private var weeks: [[Date?]] {
        guard let dayCount = calendar.range(of: .day, in: .month, for: visibleMonth)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: visibleMonth) - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: visibleMonth))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    private func dayNumber(_ day: Date) -> String {
        String(calendar.component(.day, from: day))
    }
}

nonisolated extension Calendar {
    /// The first day of the month containing `date`.
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}
