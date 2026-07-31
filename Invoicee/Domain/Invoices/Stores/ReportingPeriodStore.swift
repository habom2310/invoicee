import Foundation
import Combine

/// Tracks the currently selected reporting month/year for invoice analytics.
@MainActor
final class ReportingPeriodStore: ObservableObject {
    @Published private(set) var selectedMonth: Int
    @Published private(set) var selectedYear: Int

    init(calendar: Calendar = .current, referenceDate: Date = .now) {
        selectedMonth = calendar.component(.month, from: referenceDate)
        selectedYear = calendar.component(.year, from: referenceDate)
    }

    func set(month: Int, year: Int) {
        guard selectedMonth != month || selectedYear != year else { return }
        selectedMonth = month
        selectedYear = year
    }
}
