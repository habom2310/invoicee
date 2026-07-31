import Foundation

nonisolated extension Date {
    /// Formats the invoice date using `dd-MM-yyyy`.
    func formattedInvoiceDate() -> String {
        ReportingDateFormatter.invoiceDay(self)
    }
}
