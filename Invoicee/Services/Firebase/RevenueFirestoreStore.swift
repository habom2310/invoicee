import Foundation
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

/// Persists revenue entries per user in Firestore.
protocol RevenueStoring: AnyObject {
    func fetchEntries(for userID: String) async throws -> [RevenueDayEntry]
    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, userID: String) async throws -> RevenueDayEntry
}

final class RevenueFirestoreStore: RevenueStoring {
#if canImport(FirebaseFirestore)
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func fetchEntries(for userID: String) async throws -> [RevenueDayEntry] {
        // Firestore would require a composite index to combine `where` with `order`, so
        // this filters by user and leaves ordering to the caller.
        let snapshot = try await collection()
            .whereField("userID", isEqualTo: userID)
            .getDocuments()

        return snapshot.documents.compactMap {
            Self.entry(from: $0.data(), documentID: $0.documentID)
        }
    }

    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, userID: String) async throws -> RevenueDayEntry {
        // One document per user per day, so re-saving a day overwrites rather than adding.
        let docID = documentID ?? Self.documentID(for: userID, date: date)
        try await collection()
            .document(docID)
            .setData(Self.payload(date: date, streams: streams, userID: userID), merge: true)
        return RevenueDayEntry(documentID: docID, date: date, streams: streams)
    }

    private func collection() -> CollectionReference {
        db.collection("revenue")
    }
#else
    init() {}

    func fetchEntries(for userID: String) async throws -> [RevenueDayEntry] {
        throw FirestoreUnavailableError()
    }

    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, userID: String) async throws -> RevenueDayEntry {
        throw FirestoreUnavailableError()
    }
#endif
}

#if canImport(FirebaseFirestore)
private extension RevenueFirestoreStore {
    static func payload(date: Date, streams: [RevenueStreamValue], userID: String) -> [String: Any] {
        [
            "userID": userID,
            "date": Timestamp(date: date),
            "streams": streams.map { ["name": $0.name, "amount": $0.amount.doubleValue] },
            "updatedAt": Timestamp(date: Date())
        ]
    }

    static func entry(from data: [String: Any], documentID: String) -> RevenueDayEntry? {
        guard let timestamp = data["date"] as? Timestamp else { return nil }

        let streams = (data["streams"] as? [[String: Any]] ?? []).compactMap { value -> RevenueStreamValue? in
            guard let name = value["name"] as? String else { return nil }
            return RevenueStreamValue(name: name,
                                      amount: Decimal(roundedFrom: value["amount"] as? Double ?? 0))
        }

        return RevenueDayEntry(documentID: documentID,
                               date: timestamp.dateValue(),
                               streams: streams)
    }

    static func documentID(for userID: String, date: Date) -> String {
        "\(userID)_\(ReportingDateFormatter.isoDay(date))"
    }
}
#endif
