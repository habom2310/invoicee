import Foundation
import UIKit

/// Writes an invoice's attachment to a temporary file ready for upload, resizing images
/// to the user's chosen quality on the way.
///
/// `nonisolated` because the sync coordinator calls it while uploading.
nonisolated enum InvoiceDriveExporter {
    private static let jpegQuality: CGFloat = 0.85

    static func exportInvoiceImage(_ invoice: CapturedInvoice,
                                   metadata: DriveUploadMetadata,
                                   quality: InvoiceImageQuality) throws -> URL? {
        guard let imageData = invoice.imageData else { return nil }
        return try write(resized(imageData, to: quality) ?? imageData, named: metadata.fileName)
    }

    static func exportInvoicePDF(_ invoice: CapturedInvoice,
                                 metadata: DriveUploadMetadata) throws -> URL? {
        guard let pdfData = invoice.pdfData else { return nil }
        return try write(pdfData, named: metadata.fileName)
    }

    private static func write(_ data: Data, named fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        // A previous run may have left the file behind if the upload threw mid-flight.
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Re-encodes the image smaller, or `nil` when it is already within the target.
    private static func resized(_ data: Data, to quality: InvoiceImageQuality) -> Data? {
        guard let longestSide = quality.targetLongestSide,
              let image = UIImage(data: data) else { return nil }

        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > longestSide else { return nil }

        let scale = longestSide / maxSide
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        // Scale 1: `targetSize` is already in pixels, and the device's own scale factor
        // would silently multiply the upload back up to the size the user opted out of.
        format.scale = 1
        format.opaque = true

        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
}
