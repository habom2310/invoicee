import Foundation

/// Represents a captured invoice and its metadata across manual and camera flows.
struct CapturedInvoice: Identifiable, Codable, Equatable {
    /// Describes how the invoice entered the system.
    enum Method: String, Codable {
        case camera
        case manual

        var title: String {
            switch self {
            case .camera: "Camera"
            case .manual: "Manual"
            }
        }

        var iconName: String {
            switch self {
            case .camera: "camera.fill"
            case .manual: "square.and.pencil"
            }
        }
    }

    var id = UUID()
    var supplier: String
    /// What the invoice is for in total.
    var total: Decimal
    /// The share of `total` this business is claiming. Equals `total` unless split.
    var ourAmount: Decimal
    var gst: Decimal
    var date: Date
    let method: Method
    var category: String?
    var items: [ManualInvoiceItem]
    /// The attachment bytes, held locally only — Firestore carries the file *names*.
    var imageData: Data?
    var pdfData: Data?
    var remoteImageFileName: String?
    var remotePDFFileName: String?
    /// Drives remote-vs-local merge decisions, so it tracks user edits, not uploads.
    var lastEdited: Date = .now

    var formattedDate: String {
        date.formattedInvoiceDate()
    }

    var displayTotal: String {
        total.formattedCurrency()
    }

    var displayGST: String {
        gst.formattedCurrency()
    }
}

/// Captures the in-progress state for manual invoice entry.
///
/// Amounts are optional to distinguish "not filled in yet" from a genuine zero.
///
/// `nonisolated` because the OCR pass builds one off the main actor. Without it,
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` infers `@MainActor` for the memberwise
/// initialiser — which a protocol conformance would not have covered — and constructing
/// one from `InvoiceOCRProcessor` becomes a cross-isolation call.
nonisolated struct ManualInvoiceData {
    var supplier: String = ""
    var totalAmount: Decimal?
    var ourAmount: Decimal?
    var gstAmount: Decimal?
    /// `false` while Our Amount is mirroring the total; set once the user overrides it.
    var hasCustomOurAmount: Bool = false
    var selectedCategory: String?
    var newCategory: String = ""
    var date: Date = .now
    var items: [ManualInvoiceItem] = []
    /// The supplier whose remembered category auto-filled `selectedCategory`, or `nil`
    /// when the user chose it. Guards against overwriting a deliberate choice.
    var autoFilledSupplierKey: String?

    var isValid: Bool {
        !supplier.trimmed.isEmpty && totalAmount != nil
    }
}

/// Item-level details for manual invoice entry.
///
/// Amounts stay as text: these are free-form fields transcribed from a paper invoice, and
/// the app reports on the invoice total rather than summing the items.
///
/// `nonisolated` for the same reason as `ManualInvoiceData` — the OCR pass constructs these.
nonisolated struct ManualInvoiceItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var quantity: String = ""
    var unitPrice: String = ""
    var totalAmount: String = ""
}
