import Foundation

/// Which monetary column the expense and profit reports emphasise.
///
/// Lives in the domain rather than on a view model: `ExpenseMetricStore`, the profit
/// analytics, and the expense analytics all need it, and a store should not have to
/// reach into a view model to name its own state.
nonisolated enum ExpenseMetric: String, CaseIterable, Identifiable, Codable {
    case totalAmount
    case ourAmount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .totalAmount: "Total Amount"
        case .ourAmount: "Our Amount"
        }
    }

    /// The amount this metric reads from an invoice.
    func value(in invoice: CapturedInvoice) -> Decimal {
        switch self {
        case .totalAmount: invoice.total
        case .ourAmount: invoice.ourAmount
        }
    }
}
