import Foundation

/// The period a reporting screen is scoped to.
///
/// Every reporting tab offered the same week/month/year choice through its own
/// private enum (`ExpenseAnalyticsViewModel.Filter`, `RevenueViewModel.SummaryFilter`,
/// `ProfitAnalyticsViewModel.Filter`) with identical cases and display names. One
/// shared type means the pickers, the range maths, and the export file naming can
/// never drift apart.
nonisolated enum ReportingPeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }
}

nonisolated extension Calendar {
    /// The date range `period` covers for the given month/year selection.
    ///
    /// `week` ignores the selection and always describes the week containing
    /// `referenceDate`, matching what every screen labels "This Week".
    func range(for period: ReportingPeriod,
               month: Int,
               year: Int,
               referenceDate: Date = .now) -> ReportingDateRange? {
        switch period {
        case .week: reportingWeek(containing: referenceDate)
        case .month: reportingMonth(month: month, year: year)
        case .year: reportingYear(year)
        }
    }
}
