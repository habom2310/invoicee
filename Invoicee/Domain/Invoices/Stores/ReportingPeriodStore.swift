import Foundation
import Combine

/// The period the reporting tabs share.
///
/// Revenue, Expense, and Profit all answer questions about the same stretch of trading,
/// so choosing one on any of them moves the other two. Each view model keeps its own
/// `selection` and mirrors this store, rather than reading it from `body`.
///
/// The invoice list is deliberately not a participant: it always shows one month, and it
/// clamps that month onto the months holding invoices. Letting that clamp write here
/// would move the reports whenever the list was opened.
@MainActor
final class ReportingPeriodStore: ObservableObject {
    @Published private(set) var selection: ReportingPeriodSelection

    init(period: ReportingPeriod = .day, calendar: Calendar = .current, referenceDate: Date = .now) {
        selection = ReportingPeriodSelection(period: period, containing: referenceDate, calendar: calendar)
    }

    func set(_ selection: ReportingPeriodSelection) {
        guard self.selection != selection else { return }
        self.selection = selection
    }
}
