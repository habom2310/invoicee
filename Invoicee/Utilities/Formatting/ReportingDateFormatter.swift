import Foundation

/// Shared date format helpers used by reporting and analytics screens.
enum ReportingDateFormatter {
    static let monthSymbols: [String] = makeFormatter().monthSymbols
    static let shortMonthSymbols: [String] = makeFormatter().shortMonthSymbols

    static func shortName(for month: Int) -> String {
        guard month >= 1, month <= shortMonthSymbols.count else { return "Month" }
        return shortMonthSymbols[month - 1]
    }

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
