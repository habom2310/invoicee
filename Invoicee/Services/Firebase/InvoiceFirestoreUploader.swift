import Foundation
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

protocol InvoiceFirestoreUploading {
    func upload(invoice: CapturedInvoice, imageFileName: String?, pdfFileName: String?, userID: String) async throws
    func delete(invoiceID: UUID) async throws
    func fetchInvoices(for userID: String) async throws -> [CapturedInvoice]
}

/// Raised when the app is built without Firestore, so the sync paths fail with a message
/// instead of silently doing nothing.
struct FirestoreUnavailableError: LocalizedError {
    let errorDescription: String? = "Firebase Firestore is not available in this build."
}

/// Firebase-backed implementation of `InvoiceFirestoreUploading`.
final class InvoiceFirestoreUploader: InvoiceFirestoreUploading {
#if canImport(FirebaseFirestore)
    private static let collectionName = "invoices"

    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func upload(invoice: CapturedInvoice, imageFileName: String?, pdfFileName: String?, userID: String) async throws {
        try await document(for: invoice.id).setData(Self.payload(from: invoice,
                                                                imageFileName: imageFileName,
                                                                pdfFileName: pdfFileName,
                                                                userID: userID),
                                                    merge: true)
    }

    func delete(invoiceID: UUID) async throws {
        try await document(for: invoiceID).delete()
    }

    func fetchInvoices(for userID: String) async throws -> [CapturedInvoice] {
        let collection = db.collection(Self.collectionName)
        var snapshot = try await collection.whereField("driveAccountID", isEqualTo: userID).getDocuments()

        // Invoices written before `driveAccountID` existed carry only `userID`. Current
        // uploads set both, so this second query only runs for an account whose documents
        // all predate that field — or one with no invoices at all.
        if snapshot.isEmpty {
            snapshot = try await collection.whereField("userID", isEqualTo: userID).getDocuments()
        }

        return snapshot.documents.compactMap {
            Self.invoice(from: $0.data(), documentID: $0.documentID)
        }
    }

    private func document(for invoiceID: UUID) -> DocumentReference {
        db.collection(Self.collectionName).document(invoiceID.uuidString)
    }
#else
    init() {}

    func upload(invoice: CapturedInvoice, imageFileName: String?, pdfFileName: String?, userID: String) async throws {
        throw FirestoreUnavailableError()
    }

    func delete(invoiceID: UUID) async throws {
        throw FirestoreUnavailableError()
    }

    func fetchInvoices(for userID: String) async throws -> [CapturedInvoice] {
        throw FirestoreUnavailableError()
    }
#endif
}

#if canImport(FirebaseFirestore)
private extension InvoiceFirestoreUploader {
    static func payload(from invoice: CapturedInvoice,
                        imageFileName: String?,
                        pdfFileName: String?,
                        userID: String) -> [String: Any] {
        let resolvedImageFileName = imageFileName ?? invoice.remoteImageFileName
        let resolvedPDFFileName = pdfFileName ?? invoice.remotePDFFileName

        var payload: [String: Any] = [
            "id": invoice.id.uuidString,
            "supplier": invoice.supplier,
            "total": invoice.total.doubleValue,
            "ourAmount": invoice.ourAmount.doubleValue,
            "gst": invoice.gst.doubleValue,
            "date": Timestamp(date: invoice.date),
            "method": invoice.method.rawValue,
            "hasImage": invoice.imageData != nil,
            "hasPdf": invoice.pdfData != nil || resolvedPDFFileName != nil,
            "lastEdited": Timestamp(date: invoice.lastEdited),
            "userID": userID,
            "driveAccountID": userID,
            "last_updated": Timestamp(date: Date()),
            "items": invoice.items.map { item in
                [
                    "id": item.id.uuidString,
                    "name": item.name,
                    "quantity": item.quantity,
                    "unitPrice": item.unitPrice,
                    "totalAmount": item.totalAmount
                ]
            }
        ]

        // Written only when set. Casting `nil` through `as Any` — as this did for
        // `category` and the file names — stores an `NSNull`, which reads back as a
        // present-but-null field rather than an absent one.
        payload["category"] = invoice.category
        payload["imageFileName"] = resolvedImageFileName
        payload["pdfFileName"] = resolvedPDFFileName
        return payload
    }

    static func invoice(from data: [String: Any], documentID: String) -> CapturedInvoice? {
        guard let supplier = data["supplier"] as? String,
              let timestamp = data["date"] as? Timestamp else { return nil }

        // Older documents recorded only `ourAmount`.
        guard let total = (data["total"] as? Double) ?? (data["ourAmount"] as? Double) else { return nil }
        let ourAmount = (data["ourAmount"] as? Double) ?? total
        let date = timestamp.dateValue()

        // `lastEdited` is the user's edit time and drives merge decisions; `last_updated`
        // is only the upload stamp, so it must never win — treating it as the edit time
        // made every remote copy look newer than the local one.
        let lastEdited = (data["lastEdited"] as? Timestamp)?.dateValue()
            ?? (data["last_updated"] as? Timestamp)?.dateValue()
            ?? date

        let items = (data["items"] as? [[String: Any]] ?? []).map { item in
            ManualInvoiceItem(id: (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                              name: item["name"] as? String ?? "",
                              quantity: item["quantity"] as? String ?? "",
                              unitPrice: item["unitPrice"] as? String ?? "",
                              totalAmount: item["totalAmount"] as? String ?? "")
        }

        return CapturedInvoice(
            // A document ID that is not a UUID would mint a fresh one on every fetch,
            // duplicating the invoice locally each time, so skip it instead.
            id: UUID(uuidString: documentID) ?? UUID(uuidString: data["id"] as? String ?? "") ?? UUID(),
            supplier: supplier,
            total: Decimal(roundedFrom: total),
            ourAmount: Decimal(roundedFrom: ourAmount),
            gst: Decimal(roundedFrom: data["gst"] as? Double ?? 0),
            date: date,
            method: CapturedInvoice.Method(rawValue: data["method"] as? String ?? "") ?? .manual,
            category: (data["category"] as? String)?.trimmed.nilIfEmpty,
            items: items,
            imageData: nil,
            pdfData: nil,
            remoteImageFileName: data["imageFileName"] as? String,
            remotePDFFileName: data["pdfFileName"] as? String,
            lastEdited: lastEdited
        )
    }
}
#endif
