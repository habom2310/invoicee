import Foundation
import Combine

@MainActor
final class ReportingPeriodStore: ObservableObject {
    static let shared = ReportingPeriodStore()

    @Published private(set) var selectedMonth: Int
    @Published private(set) var selectedYear: Int

    private let calendar: Calendar

    private init(calendar: Calendar = .current) {
        self.calendar = calendar
        let now = Date()
        selectedMonth = calendar.component(.month, from: now)
        selectedYear = calendar.component(.year, from: now)
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
