import Foundation

/// Shared date format helpers used by reporting and analytics screens.
///
/// Every formatter here is cached: `DateFormatter` allocation is expensive and these
/// are called once per table row.
///
/// `nonisolated` because the sync tracker and the OCR pass format dates from outside
/// the main actor.
nonisolated enum ReportingDateFormatter {
    // MARK: - Month names

    /// Localised month names, e.g. "January".
    static let monthSymbols: [String] = DateFormatter().monthSymbols
    /// Localised abbreviated month names, e.g. "Jan".
    static let shortMonthSymbols: [String] = DateFormatter().shortMonthSymbols

    static func name(for month: Int) -> String {
        symbol(for: month, in: monthSymbols)
    }

    static func shortName(for month: Int) -> String {
        symbol(for: month, in: shortMonthSymbols)
    }

    /// Stable, locale-independent month abbreviation for use in file names.
    static func fileNameMonth(for month: Int) -> String {
        symbol(for: month, in: posixShortMonthSymbols)
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Dates

    /// `dd-MM-yyyy`, the format invoices are displayed with.
    static func invoiceDay(_ date: Date) -> String {
        invoiceDayFormatter.string(from: date)
    }

    /// Parses a `dd-MM-yyyy` string, the inverse of `invoiceDay(_:)`.
    static func parseInvoiceDay(_ string: String) -> Date? {
        invoiceDayFormatter.date(from: string)
    }

    /// Localised medium date, e.g. "12 Jan 2026".
    static func mediumDate(_ date: Date) -> String {
        mediumDateFormatter.string(from: date)
    }

    /// `yyyy-MM-dd`, used for CSV columns and document identifiers.
    static func isoDay(_ date: Date) -> String {
        isoDayFormatter.string(from: date)
    }

    /// Localised `MMM yyyy`, used for monthly rollup rows.
    static func monthAndYear(_ date: Date) -> String {
        monthYearFormatter.string(from: date)
    }

    /// `MMM_dd_yyyy`, used inside exported file names.
    static func fileNameDay(_ date: Date) -> String {
        fileNameDayFormatter.string(from: date)
    }

    /// `yyyyMMdd-HHmm`, used to make exported file names unique.
    static func fileNameTimestamp(_ date: Date) -> String {
        fileNameTimestampFormatter.string(from: date)
    }

    // MARK: - Drive folder names

    /// `yyyy`, the Drive year folder.
    static func yearFolder(_ date: Date) -> String {
        yearFolderFormatter.string(from: date)
    }

    /// `MM`, the Drive month folder.
    static func monthFolder(_ date: Date) -> String {
        monthFolderFormatter.string(from: date)
    }

    /// `yyyy_MM_dd`, the date portion of an uploaded attachment's name.
    static func uploadDay(_ date: Date) -> String {
        uploadDayFormatter.string(from: date)
    }

    // MARK: - Export file name fragments

    /// e.g. `Week_Jan_05_2026_Jan_11_2026`.
    static func weekIdentifier(_ range: ReportingDateRange?) -> String {
        guard let range else { return "Week_Current" }
        return "Week_\(fileNameDay(range.start))_\(fileNameDay(range.end))"
    }

    /// e.g. `Jan_2026`.
    static func monthIdentifier(month: Int, year: Int) -> String {
        "\(fileNameMonth(for: month))_\(year)"
    }

    // MARK: - Private

    private static func symbol(for month: Int, in symbols: [String]) -> String {
        guard month >= 1, month <= symbols.count else { return "Month" }
        return symbols[month - 1]
    }

    private static let posixShortMonthSymbols: [String] = makePOSIXFormatter().shortMonthSymbols

    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter
    }()

    private static let invoiceDayFormatter = makePOSIXFormatter(dateFormat: "dd-MM-yyyy")
    private static let isoDayFormatter = makePOSIXFormatter(dateFormat: "yyyy-MM-dd")
    private static let fileNameDayFormatter = makePOSIXFormatter(dateFormat: "MMM_dd_yyyy")
    private static let fileNameTimestampFormatter = makePOSIXFormatter(dateFormat: "yyyyMMdd-HHmm")
    private static let yearFolderFormatter = makePOSIXFormatter(dateFormat: "yyyy")
    private static let monthFolderFormatter = makePOSIXFormatter(dateFormat: "MM")
    private static let uploadDayFormatter = makePOSIXFormatter(dateFormat: "yyyy_MM_dd")

    private static func makePOSIXFormatter(dateFormat: String? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let dateFormat {
            formatter.dateFormat = dateFormat
        }
        return formatter
    }
}
