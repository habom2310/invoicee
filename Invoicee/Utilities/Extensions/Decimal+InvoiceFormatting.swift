import Foundation

/// `nonisolated` because CSV building and the sync services format amounts off the main
/// actor. Nothing here touches shared mutable state.
nonisolated extension Decimal {
    /// Parses using a fixed locale, for values that came from a file, the network, or a
    /// digits-only text field rather than from locale-aware user input.
    ///
    /// Note this shadows `Decimal(string:locale:)`'s defaulted form — call that
    /// explicitly with `locale: .current` when the input *is* locale-aware.
    init?(string: String) {
        self.init(string: string, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Converts a `Double` without dragging binary floating-point noise into the value.
    ///
    /// `Decimal(0.1)` expands the full binary representation
    /// (`0.1000000000000000055511151231257827`); round-tripping through the shortest
    /// description that still identifies the `Double` keeps money values exact.
    init(roundedFrom double: Double) {
        guard double.isFinite else {
            self = .zero
            return
        }
        self = Decimal(string: "\(double)") ?? Decimal(double)
    }

    func formattedCurrency(omitSymbol: Bool = false) -> String {
        let formatter = omitSymbol ? NumberFormatter.invoiceCurrencyPlain : NumberFormatter.invoiceCurrency
        return formatter.string(from: NSDecimalNumber(decimal: self)) ?? ""
    }

    /// Unformatted digits, for CSV columns and text fields.
    var plainString: String {
        NSDecimalNumber(decimal: self).stringValue
    }

    /// Lossy conversion used only for percentage formatting and chart geometry.
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}
