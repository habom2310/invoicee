import Foundation
import Combine

/// The month the invoice list is showing.
///
/// Its own store rather than a share of `ReportingPeriodStore`: the list only ever shows
/// a month, and it clamps that month onto the months that hold invoices. See the note on
/// `ReportingPeriodStore` for why that clamp is kept away from the reports.
@MainActor
final class InvoiceMonthStore: ObservableObject {
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
