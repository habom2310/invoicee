import Foundation

struct CapturedInvoice: Identifiable {
    enum Method {
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
    var gst: Decimal
    var date: Date
    let method: Method
    var category: String?
    var items: [ManualInvoiceItem]
    var imageData: Data?

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

struct ManualInvoiceData {
    var supplier: String = ""
    var totalAmount: Decimal?
    var gstAmount: Decimal?
    var selectedCategory: String?
    var newCategory: String = ""
    var date: Date = .now
    var items: [ManualInvoiceItem] = []

    var isValid: Bool {
        !supplier.trimmed.isEmpty && totalAmount != nil
    }

    mutating func addItem() {
        items.append(ManualInvoiceItem())
    }
}

struct ManualInvoiceItem: Identifiable {
    let id = UUID()
    var name: String = ""
    var quantity: String = ""
    var unitPrice: String = ""
    var totalAmount: String = ""
}
