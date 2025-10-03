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
    var total: String
    var date: Date
    let method: Method
    var category: String?
    var items: [ManualInvoiceItem]
    var imageData: Data?

    var formattedDate: String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    var displayTotal: String {
        let trimmed = total.trimmed
        return trimmed.isEmpty ? "—" : trimmed
    }
}

struct ManualInvoiceData {
    var supplier: String = ""
    var totalAmount: String = ""
    var selectedCategory: String?
    var newCategory: String = ""
    var date: Date = .now
    var items: [ManualInvoiceItem] = []

    var isValid: Bool {
        !supplier.trimmed.isEmpty && !totalAmount.trimmed.isEmpty
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
    var gst: String = ""
}
