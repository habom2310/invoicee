import Foundation

extension Decimal {
    init?(string: String) {
        self.init(string: string, locale: Locale(identifier: "en_US_POSIX"))
    }

    func formattedCurrency() -> String {
        NumberFormatter.invoiceCurrency.string(from: NSDecimalNumber(decimal: self)) ?? ""
    }

    var plainString: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}
