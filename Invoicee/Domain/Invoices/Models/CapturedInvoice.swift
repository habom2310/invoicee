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
    var total: Decimal
    var ourAmount: Decimal
    var gst: Decimal
    var date: Date
    let method: Method
    var category: String?
    var items: [ManualInvoiceItem]
    var imageData: Data?
    var remoteImageFileName: String?
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

    var displayOurAmount: String {
        ourAmount.formattedCurrency()
    }
}

/// Captures the in-progress state for manual invoice entry.
struct ManualInvoiceData {
    var supplier: String = ""
    var totalAmount: Decimal?
    var ourAmount: Decimal?
    var gstAmount: Decimal?
    var hasCustomOurAmount: Bool = false
    var selectedCategory: String?
    var newCategory: String = ""
    var date: Date = .now
    var items: [ManualInvoiceItem] = []
    /// Tracks whether the currently selected category was auto-filled for a supplier.
    var autoFilledSupplierKey: String? = nil

    var isValid: Bool {
        !supplier.trimmed.isEmpty && totalAmount != nil
    }
}

/// Item-level details for manual invoice entry.
struct ManualInvoiceItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var quantity: String = ""
    var unitPrice: String = ""
    var totalAmount: String = ""
}
