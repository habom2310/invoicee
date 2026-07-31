import Foundation

/// `nonisolated` so amounts can be formatted off the main actor. `NumberFormatter` is
/// safe for concurrent formatting once configured, and these are never mutated after
/// construction.
nonisolated extension NumberFormatter {
    /// Shared currency formatter configured for two decimal places.
    static let invoiceCurrency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    /// Currency formatter without the leading symbol, useful for editing states.
    static let invoiceCurrencyPlain: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}
