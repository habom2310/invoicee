import Foundation
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

protocol InvoiceFirestoreUploading {
    func upload(invoice: CapturedInvoice, imageFileName: String?, userID: String) async throws
    func delete(invoiceID: UUID) async throws
    func fetchInvoices(for userID: String) async throws -> [CapturedInvoice]
}

/// Firebase-backed implementation of `InvoiceFirestoreUploading`.
final class InvoiceFirestoreUploader: InvoiceFirestoreUploading {

#if canImport(FirebaseFirestore)
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func upload(invoice: CapturedInvoice, imageFileName: String?, userID: String) async throws {
        let document = db.collection("invoices").document(invoice.id.uuidString)
        let data: [String: Any] = Self.payload(from: invoice, imageFileName: imageFileName, userID: userID)
        try await document.setData(data, merge: true)
    }

    func delete(invoiceID: UUID) async throws {
        let document = db.collection("invoices").document(invoiceID.uuidString)
        try await document.delete()
    }

    func fetchInvoices(for userID: String) async throws -> [CapturedInvoice] {
        let collection = db.collection("invoices")
        let primary = try await collection
            .whereField("driveAccountID", isEqualTo: userID)
            .getDocuments()

        let snapshot: QuerySnapshot
        if primary.isEmpty {
            snapshot = try await collection
                .whereField("userID", isEqualTo: userID)
                .getDocuments()
        } else {
            snapshot = primary
        }

        return snapshot.documents.compactMap { document in
            Self.invoice(from: document.data(), documentID: document.documentID)
        }
    }
#else
    init() {}

    func upload(invoice: CapturedInvoice, imageFileName: String?, userID: String) async throws {
        throw NSError(domain: "InvoiceFirestoreUploader", code: 0, userInfo: [NSLocalizedDescriptionKey: "FirebaseFirestore not available on this platform."])
    }

    func delete(invoiceID: UUID) async throws {
        throw NSError(domain: "InvoiceFirestoreUploader", code: 0, userInfo: [NSLocalizedDescriptionKey: "FirebaseFirestore not available on this platform."])
    }

    func fetchInvoices(for userID: String) async throws -> [CapturedInvoice] {
        throw NSError(domain: "InvoiceFirestoreUploader", code: 0, userInfo: [NSLocalizedDescriptionKey: "FirebaseFirestore not available on this platform."])
    }
#endif

#if canImport(FirebaseFirestore)
    private static func payload(from invoice: CapturedInvoice, imageFileName: String?, userID: String) -> [String: Any] {
        var payload: [String: Any] = [
            "id": invoice.id.uuidString,
            "supplier": invoice.supplier,
            "total": NSDecimalNumber(decimal: invoice.total).doubleValue,
            "ourAmount": NSDecimalNumber(decimal: invoice.ourAmount).doubleValue,
            "gst": NSDecimalNumber(decimal: invoice.gst).doubleValue,
            "date": Timestamp(date: invoice.date),
            "method": invoice.method.rawValue,
            "category": invoice.category as Any,
            "hasImage": invoice.imageData != nil,
            "imageFileName": (imageFileName ?? invoice.remoteImageFileName) as Any,
            "lastEdited": Timestamp(date: invoice.lastEdited),
            "userID": userID,
            "driveAccountID": userID,
            "last_updated": Timestamp(date: Date())
        ]

        let items = invoice.items.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "name": item.name,
                "quantity": item.quantity,
                "unitPrice": item.unitPrice,
                "totalAmount": item.totalAmount
            ]
        }
        payload["items"] = items
        return payload
    }

    private static func invoice(from data: [String: Any], documentID: String) -> CapturedInvoice? {
        guard let supplier = data["supplier"] as? String else { return nil }

        let totalValue = (data["total"] as? Double) ?? (data["ourAmount"] as? Double)
        guard let totalValue else { return nil }

        let ourAmountValue = (data["ourAmount"] as? Double) ?? totalValue
        let gstValue = data["gst"] as? Double ?? 0

        guard let timestamp = data["date"] as? Timestamp else { return nil }
        let date = timestamp.dateValue()

        let methodRaw = data["method"] as? String ?? CapturedInvoice.Method.manual.rawValue
        let method = CapturedInvoice.Method(rawValue: methodRaw) ?? .manual

        let categoryValue = (data["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = categoryValue?.isEmpty == true ? nil : categoryValue

        let lastEdited: Date
        if let updated = data["last_updated"] as? Timestamp {
            lastEdited = updated.dateValue()
        } else if let lastEditedTimestamp = data["lastEdited"] as? Timestamp {
            lastEdited = lastEditedTimestamp.dateValue()
        } else {
            lastEdited = date
        }

        let itemsData = data["items"] as? [[String: Any]] ?? []
        let items: [ManualInvoiceItem] = itemsData.map { itemData in
            ManualInvoiceItem(
                name: itemData["name"] as? String ?? "",
                quantity: itemData["quantity"] as? String ?? "",
                unitPrice: itemData["unitPrice"] as? String ?? "",
                totalAmount: itemData["totalAmount"] as? String ?? ""
            )
        }

        let identifier = UUID(uuidString: documentID) ?? UUID()

        return CapturedInvoice(
            id: identifier,
            supplier: supplier,
            total: Decimal(totalValue),
            ourAmount: Decimal(ourAmountValue),
            gst: Decimal(gstValue),
            date: date,
            method: method,
            category: category,
            items: items,
            imageData: nil,
            remoteImageFileName: data["imageFileName"] as? String,
            lastEdited: lastEdited
        )
    }
#endif
}
