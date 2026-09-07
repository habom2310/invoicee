import Foundation
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

/// Persists revenue entries per user in Firestore.
protocol RevenueStoring: AnyObject {
    func fetchEntries(for identity: SyncIdentity) async throws -> [RevenueDayEntry]
    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, identity: SyncIdentity) async throws -> RevenueDayEntry
}

final class RevenueFirestoreStore: RevenueStoring {
#if canImport(FirebaseFirestore)
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func fetchEntries(for identity: SyncIdentity) async throws -> [RevenueDayEntry] {
        // Firestore would require a composite index to combine `where` with `order`, so
        // this filters by user and leaves ordering to the caller.
        //
        // Two filters for the same reason as invoices: entries written before Firebase
        // Auth carry only the Google account ID, and each filter has to mirror a clause
        // in the security rules for the query to be accepted at all.
        async let owned = collection().whereField("ownerUID", isEqualTo: identity.uid).getDocuments()
        async let legacy = collection().whereField("userID", isEqualTo: identity.googleAccountID).getDocuments()

        var documents: [String: [String: Any]] = [:]
        for document in try await owned.documents + legacy.documents {
            documents[document.documentID] = document.data()
        }

        return documents.compactMap { Self.entry(from: $0.value, documentID: $0.key) }
    }

    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, identity: SyncIdentity) async throws -> RevenueDayEntry {
        // One document per user per day, so re-saving a day overwrites rather than adding.
        // The ID still derives from the Google account: re-keying it on `uid` would strand
        // the existing day's entry and silently start a duplicate alongside it.
        let docID = documentID ?? Self.documentID(for: identity.googleAccountID, date: date)
        try await collection()
            .document(docID)
            .setData(Self.payload(date: date, streams: streams, identity: identity), merge: true)
        return RevenueDayEntry(documentID: docID, date: date, streams: streams)
    }

    private func collection() -> CollectionReference {
        db.collection("revenue")
    }
#else
    init() {}

    func fetchEntries(for identity: SyncIdentity) async throws -> [RevenueDayEntry] {
        throw FirestoreUnavailableError()
    }

    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, identity: SyncIdentity) async throws -> RevenueDayEntry {
        throw FirestoreUnavailableError()
    }
#endif
}

#if canImport(FirebaseFirestore)
private extension RevenueFirestoreStore {
    static func payload(date: Date, streams: [RevenueStreamValue], identity: SyncIdentity) -> [String: Any] {
        [
            "ownerUID": identity.uid,
            "userID": identity.googleAccountID,
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
