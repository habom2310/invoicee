import Foundation
import Combine

/// Tracks the currently selected reporting month/year for invoice analytics.
@MainActor
final class ReportingPeriodStore: ObservableObject {
    @Published private(set) var selectedMonth: Int
    @Published private(set) var selectedYear: Int

    private let calendar: Calendar

    init(calendar: Calendar = .current, referenceDate: Date = .now) {
        self.calendar = calendar
        selectedMonth = calendar.component(.month, from: referenceDate)
        selectedYear = calendar.component(.year, from: referenceDate)
    }

    func set(month: Int, year: Int) {
        guard selectedMonth != month || selectedYear != year else { return }
        selectedMonth = month
        selectedYear = year
    }

    func resetToCurrentDate() {
        let now = Date()
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)
        set(month: month, year: year)
    }
}
