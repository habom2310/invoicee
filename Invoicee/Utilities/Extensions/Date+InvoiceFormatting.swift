import Foundation

extension Date {
    /// Formats the invoice date using `dd-MM-yyyy`.
    func formattedInvoiceDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy"
        return formatter.string(from: self)
    }
}
