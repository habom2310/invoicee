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

    init(documentID: String, date: Date, streams: [RevenueStreamValue]) {
        self.documentID = documentID
        self.date = date
        self.streams = streams
    }

    var id: String {
        documentID
    }

    var total: Decimal {
        streams.reduce(into: Decimal.zero) { partialResult, value in
            partialResult += value.amount
        }
    }

    func containsStream(named name: String) -> Bool {
        streams.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
