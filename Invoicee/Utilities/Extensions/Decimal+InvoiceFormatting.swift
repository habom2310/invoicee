import Foundation

extension Decimal {
    init?(string: String) {
        self.init(string: string, locale: Locale(identifier: "en_US_POSIX"))
    }

    func formattedCurrency(omitSymbol: Bool = false) -> String {
        let formatter = omitSymbol ? NumberFormatter.invoiceCurrencyPlain : NumberFormatter.invoiceCurrency
        return formatter.string(from: NSDecimalNumber(decimal: self)) ?? ""
    }

    var plainString: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}
