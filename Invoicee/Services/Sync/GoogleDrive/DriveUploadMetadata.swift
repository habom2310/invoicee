import Foundation
import UniformTypeIdentifiers

/// Describes folder and file naming for Drive uploads.
///
/// `nonisolated` because the sync tracker parses upload names from inside its actor.
nonisolated struct DriveUploadMetadata {
    /// The parts of an upload file name: `<yyyy_MM_dd>_<supplier>_<increment>[_image<n>]`.
    struct ParsedFileName {
        let baseName: String
        let increment: Int
        let imageNumber: Int?
    }

    let invoiceDate: Date
    let supplier: String
    let baseFolderName: String
    let increment: Int
    let imageNumber: Int?
    private let fileExtension: String

    init(invoiceDate: Date,
         supplier: String,
         baseFolderName: String,
         fileExtension: String,
         increment: Int,
         imageNumber: Int? = nil) {
        self.invoiceDate = invoiceDate
        self.supplier = supplier
        self.baseFolderName = baseFolderName
        self.fileExtension = fileExtension.lowercased()
        self.increment = increment
        self.imageNumber = imageNumber
    }

    var yearFolderName: String {
        ReportingDateFormatter.yearFolder(invoiceDate)
    }

    var monthFolderName: String {
        ReportingDateFormatter.monthFolder(invoiceDate)
    }

    var fileName: String {
        var name = "\(Self.baseName(for: invoiceDate, supplier: supplier))_\(increment)"
        if let imageNumber {
            name += "_image\(imageNumber)"
        }
        return "\(name).\(fileExtension)"
    }

    /// `<base>/<yyyy>/<MM>/<fileName>` — how an upload is recorded in the sync tracker.
    var drivePath: String {
        "\(baseFolderName)/\(yearFolderName)/\(monthFolderName)/\(fileName)"
    }

    var mimeType: String {
        UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func baseName(for invoiceDate: Date, supplier: String) -> String {
        "\(ReportingDateFormatter.uploadDay(invoiceDate))_\(slug(from: supplier))"
    }

    static func parseFileName(from path: String) -> ParsedFileName? {
        let lastPathComponent = path.split(separator: "/").last.map(String.init) ?? path
        let stem = lastPathComponent.lastIndex(of: ".")
            .map { String(lastPathComponent[..<$0]) } ?? lastPathComponent

        var components = stem.split(separator: "_")
        // A name is at least `yyyy_MM_dd_<supplier>`; anything shorter is not ours.
        guard components.count >= 4 else { return nil }

        let imagePrefix = "image"
        var imageNumber: Int?
        if let last = components.last,
           last.hasPrefix(imagePrefix),
           let value = Int(last.dropFirst(imagePrefix.count)) {
            imageNumber = value
            components.removeLast()
        }

        guard let incrementComponent = components.last,
              let increment = Int(incrementComponent) else { return nil }
        components.removeLast()

        guard !components.isEmpty else { return nil }
        return ParsedFileName(baseName: components.joined(separator: "_"),
                              increment: increment,
                              imageNumber: imageNumber)
    }

    /// Reduces a supplier name to name-safe characters.
    private static func slug(from supplier: String) -> String {
        supplier.trimmed
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "_")
            .nilIfEmpty ?? "Unknown_Supplier"
    }
}
