internal import SwiftUI

extension Binding where Value == String {
    /// Filters keystrokes down to digits, optionally allowing one decimal point.
    func enforcingNumeric(allowDecimal: Bool) -> Binding<String> {
        Binding<String>(get: { wrappedValue },
                        set: { wrappedValue = $0.filteredNumeric(allowDecimal: allowDecimal) })
    }

    /// Bridges a `Decimal` amount and the text field the user types it into.
    ///
    /// Six near-identical hand-rolled bindings used to do this — three in
    /// `ManualInvoiceFormView` and three in `InvoiceDetailView` — each re-implementing
    /// "filter to digits, parse, fall back to something". They had drifted: some treated
    /// an unparseable string as zero and some as the previous value. Routing them all
    /// through here makes that decision explicit and shared.
    ///
    /// An empty or unparseable field reads as zero rather than keeping the old amount:
    /// the user has visibly cleared it, so showing the previous number would contradict
    /// what the field says.
    ///
    /// - Parameter onChange: called with the amount before and after the edit, for side
    ///   effects such as keeping a dependent field in step. Both values are needed to
    ///   tell "this field was mirroring the one that just changed" from "the user set it
    ///   deliberately", which is only decidable against the previous value.
    static func money(_ source: Binding<Decimal>,
                      onChange: ((_ oldValue: Decimal, _ newValue: Decimal) -> Void)? = nil) -> Binding<String> {
        Binding<String>(
            get: { source.wrappedValue.plainString },
            set: { text in
                let previous = source.wrappedValue
                let parsed = Decimal(string: text.filteredNumeric(allowDecimal: true)) ?? .zero
                source.wrappedValue = parsed
                onChange?(previous, parsed)
            }
        )
    }

    /// A text binding over an optional `Decimal`, where an empty field means "not set"
    /// rather than zero — the distinction manual entry needs to tell a genuine $0 invoice
    /// from one still being filled in.
    ///
    /// - Parameter placeholder: shown when the amount is unset, so a field that mirrors
    ///   another one (Our Amount following Total) can display the value it will inherit.
    static func optionalMoney(_ source: Binding<Decimal?>,
                              placeholder: @escaping () -> Decimal? = { nil },
                              onChange: ((Decimal?) -> Void)? = nil) -> Binding<String> {
        Binding<String>(
            get: { (source.wrappedValue ?? placeholder())?.plainString ?? "" },
            set: { text in
                let filtered = text.filteredNumeric(allowDecimal: true)
                let parsed = filtered.isEmpty ? nil : Decimal(string: filtered)
                source.wrappedValue = parsed
                onChange?(parsed)
            }
        )
    }
}
