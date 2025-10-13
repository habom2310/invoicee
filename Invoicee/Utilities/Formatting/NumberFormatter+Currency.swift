import Foundation

extension NumberFormatter {
    /// Shared currency formatter configured for two decimal places.
    static let invoiceCurrency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()
}
