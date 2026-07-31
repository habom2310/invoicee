import Foundation

/// The single definition of the GST rate the app reports with.
///
/// The rate used to be re-spelled in four places — `Decimal(string: "0.1")` in the
/// revenue summary, `Decimal(9)/Decimal(10)` in the profit analytics, and
/// `Decimal(string: "0.10")` in `GSTValidator` — so changing it meant finding all of
/// them, and the three could disagree silently.
///
/// # Exclusive vs inclusive
/// Australian GST is 10%, but the arithmetic depends on whether an amount already
/// contains GST:
///
/// - **GST-exclusive** amount: GST is `amount × 0.1`, gross is `amount × 1.1`.
/// - **GST-inclusive** amount: GST is `amount ÷ 11`, net is `amount × 10/11`.
///
/// The app currently treats recorded revenue and invoice totals as **GST-exclusive**
/// (`exclusive*` below), which is what the previous scattered constants computed.
/// The `inclusive*` helpers are here so switching that interpretation is a one-line
/// change per call site instead of a hunt for magic numbers.
nonisolated enum GSTRate {
    /// 10%, written as a string so the value is exact.
    ///
    /// `Decimal(0.1)` expands the binary representation of the literal
    /// (`0.1000000000000000055511151231257827`) into every money figure derived
    /// from it.
    static let percentage = Decimal(string: "0.1") ?? .zero

    /// GST to add to an amount that excludes it.
    static func exclusiveGST(on netAmount: Decimal) -> Decimal {
        netAmount * percentage
    }

    /// The GST-free portion of an amount that excludes GST — i.e. the amount itself,
    /// less the GST it will attract. Used for the profit calculation's "net revenue".
    static func exclusiveNet(of grossAmount: Decimal) -> Decimal {
        grossAmount - exclusiveGST(on: grossAmount)
    }

    /// GST already contained in an amount that includes it (`amount ÷ 11`).
    static func inclusiveGST(in grossAmount: Decimal) -> Decimal {
        grossAmount / (1 + percentage) * percentage
    }

    /// The GST-free portion of an amount that includes GST (`amount × 10/11`).
    static func inclusiveNet(of grossAmount: Decimal) -> Decimal {
        grossAmount - inclusiveGST(in: grossAmount)
    }
}
