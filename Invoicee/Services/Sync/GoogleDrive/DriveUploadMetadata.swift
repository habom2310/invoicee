import Foundation
import UniformTypeIdentifiers

/// Describes folder and file naming for Drive uploads.
struct DriveUploadMetadata {
    struct ParsedFileName {
        let baseName: String
        let increment: Int
        let imageNumber: Int?
    }

    let invoiceDate: Date
    let supplier: String
    let baseFolderName: String
    private let fileExtensionValue: String
    let increment: Int
    let imageNumber: Int?

    init(invoiceDate: Date,
         supplier: String,
         baseFolderName: String,
         fileExtension: String,
         increment: Int,
         imageNumber: Int? = nil) {
        self.invoiceDate = invoiceDate
        self.supplier = supplier
        self.baseFolderName = baseFolderName
        self.fileExtensionValue = fileExtension.lowercased()
        self.increment = increment
        self.imageNumber = imageNumber
    }

    var yearFolderName: String {
        DriveUploadMetadata.yearFormatter.string(from: invoiceDate)
    }

    var monthFolderName: String {
        DriveUploadMetadata.monthFormatter.string(from: invoiceDate)
    }

    var fileName: String {
        let base = DriveUploadMetadata.baseName(for: invoiceDate, supplier: supplier)
        var name = "\(base)_\(Self.format(value: increment))"
        if let imageNumber {
            name += "_image\(Self.format(value: imageNumber))"
        }
        return "\(name).\(fileExtensionValue)"
    }

    var mimeType: String {
        if let type = UTType(filenameExtension: fileExtensionValue) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }

    var fileExtension: String { fileExtensionValue }

    static func baseName(for invoiceDate: Date, supplier: String) -> String {
        let datePart = fileDateFormatter.string(from: invoiceDate)
        let supplierSlug = slug(from: supplier)
        return "\(datePart)_\(supplierSlug)"
    }

    private static func slug(from supplier: String) -> String {
        let trimmed = supplier.trimmed
        let components = trimmed.split { !$0.isLetter && !$0.isNumber }
        let joined = components.map { String($0) }.joined(separator: "_")
        return joined.isEmpty ? "Unknown_Supplier" : joined
    }

    static func parseFileName(from path: String) -> ParsedFileName? {
        let fileNameWithExtension = path.split(separator: "/").last.map(String.init) ?? path
        let fileName: String
        if let dotIndex = fileNameWithExtension.lastIndex(of: ".") {
            fileName = String(fileNameWithExtension[..<dotIndex])
        } else {
            fileName = fileNameWithExtension
        }
        let components = fileName.split(separator: "_")
        guard components.count >= 4 else { return nil }

        var imageNumber: Int? = nil
        var incrementComponentIndex = components.count - 1
        let lastComponent = components[incrementComponentIndex]

        if let imageValue = Self.parseImageComponent(lastComponent) {
            imageNumber = imageValue
            incrementComponentIndex -= 1
        }

        guard incrementComponentIndex >= 0,
              let incrementValue = Int(components[incrementComponentIndex]) else { return nil }

        let baseComponents = components[..<incrementComponentIndex]
        guard !baseComponents.isEmpty else { return nil }
        let baseName = baseComponents.joined(separator: "_")

        return ParsedFileName(baseName: baseName, increment: incrementValue, imageNumber: imageNumber)
    }

    private static func format(value: Int) -> String {
        String(value)
    }

    private static func parseImageComponent(_ component: Substring) -> Int? {
        guard component.hasPrefix("image") else { return nil }
        let suffix = component.dropFirst("image".count)
        return Int(suffix)
    }

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy_MM_dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
