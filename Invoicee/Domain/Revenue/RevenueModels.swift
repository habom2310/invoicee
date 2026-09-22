import Foundation

/// Represents a revenue amount for a named stream on a particular day.
struct RevenueStreamValue: Identifiable, Hashable {
    var name: String
    var amount: Decimal

    var id: String {
        name
    }
}

/// Aggregated revenue streams for a specific calendar day.
struct RevenueDayEntry: Identifiable, Hashable {
    let documentID: String
    let date: Date
    var streams: [RevenueStreamValue]

    var id: String {
        documentID
    }

    var total: Decimal {
        streams.reduce(into: Decimal.zero) { partialResult, value in
            partialResult += value.amount
        }
    }
}

/// How a period's revenue compares with the matching span of the period before it.
///
/// `previousRange` stops wherever the current period has reached, so the two totals
/// always cover the same number of elapsed days.
struct RevenuePeriodComparison: Equatable {
    enum Direction {
        case up
        case down
        case unchanged
    }

    let currentTotal: Decimal
    let previousTotal: Decimal
    let previousRange: ReportingDateRange

    var difference: Decimal {
        currentTotal - previousTotal
    }

    /// `nil` when the earlier span earned nothing, which no percentage can describe.
    var percentChange: Decimal? {
        guard previousTotal > 0 else { return nil }
        return difference / previousTotal
    }

    var direction: Direction {
        if difference > 0 {
            .up
        } else if difference < 0 {
            .down
        } else {
            .unchanged
        }
    }
}
