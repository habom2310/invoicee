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
        // Firestore may require a composite index when combining `where` + `order`.
        // Filter by user ID and sort locally to avoid that dependency.
        let snapshot = try await collection()
            .whereField("userID", isEqualTo: userID)
            .getDocuments()

        return snapshot.documents.compactMap { document in
            Self.entry(from: document.data(), documentID: document.documentID)
        }
    }

    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, userID: String) async throws -> RevenueDayEntry {
        let docID = documentID ?? Self.documentID(for: userID, date: date)
        let document = collection().document(docID)
        let data = Self.payload(date: date, streams: streams, userID: userID)
        try await document.setData(data, merge: true)
        return RevenueDayEntry(documentID: docID, date: date, streams: streams)
    }

    private func collection() -> CollectionReference {
        db.collection("revenue")
    }
#else
    init() {}

    func fetchEntries(for userID: String) async throws -> [RevenueDayEntry] {
        throw NSError(domain: "RevenueFirestoreStore",
                      code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "FirebaseFirestore not available on this platform."])
    }

    func save(date: Date, streams: [RevenueStreamValue], documentID: String?, userID: String) async throws -> RevenueDayEntry {
        throw NSError(domain: "RevenueFirestoreStore",
                      code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "FirebaseFirestore not available on this platform."])
    }
#endif
}

#if canImport(FirebaseFirestore)
private extension RevenueFirestoreStore {
    static func payload(date: Date, streams: [RevenueStreamValue], userID: String) -> [String: Any] {
        let streamArray: [[String: Any]] = streams.map { stream in
            [
                "name": stream.name,
                "amount": NSDecimalNumber(decimal: stream.amount).doubleValue
            ]
        }

        return [
            "userID": userID,
            "date": Timestamp(date: date),
            "streams": streamArray,
            "updatedAt": Timestamp(date: Date())
        ]
    }

    static func entry(from data: [String: Any], documentID: String) -> RevenueDayEntry? {
        guard let timestamp = data["date"] as? Timestamp else { return nil }
        let date = timestamp.dateValue()
        let streamData = data["streams"] as? [[String: Any]] ?? []

        let streams: [RevenueStreamValue] = streamData.compactMap { value in
            guard let name = value["name"] as? String else { return nil }
            let amountValue = value["amount"] as? Double ?? 0
            return RevenueStreamValue(name: name, amount: Decimal(amountValue))
        }

        return RevenueDayEntry(documentID: documentID, date: date, streams: streams)
    }

    static func documentID(for userID: String, date: Date) -> String {
        let dayKey = dayFormatter.string(from: date)
        return "\(userID)_\(dayKey)"
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
#endif
