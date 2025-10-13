import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Prepares invoice images for upload, resizing when necessary.
enum InvoiceDriveExporter {
    static func exportInvoiceImage(_ invoice: CapturedInvoice,
                                   metadata: DriveUploadMetadata,
                                   quality: InvoiceImageQuality) throws -> URL? {
        guard let imageData = invoice.imageData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(metadata.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let dataToWrite = resizedImageDataIfNeeded(from: imageData, quality: quality) ?? imageData
        try dataToWrite.write(to: url, options: .atomic)
        return url
    }

    private static func resizedImageDataIfNeeded(from data: Data, quality: InvoiceImageQuality) -> Data? {
        guard let longestSide = quality.targetLongestSide else { return nil }
#if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > longestSide else { return nil }
        let resized = resize(image: image, longestSide: longestSide)
        guard let jpegData = resized.jpegData(compressionQuality: 0.85) else { return nil }
        return jpegData
#elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > longestSide else { return nil }
        guard let resized = resize(image: image, longestSide: longestSide) else { return nil }
        return jpegData(from: resized, compression: 0.85)
#else
        return nil
#endif
    }

#if canImport(UIKit)
    private static func resize(image: UIImage, longestSide: CGFloat) -> UIImage {
        let originalSize = image.size
        let maxSide = max(originalSize.width, originalSize.height)
        guard maxSide > longestSide else { return image }
        let scale = longestSide / maxSide
        let newSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resized ?? image
    }
#elseif canImport(AppKit)
    private static func resize(image: NSImage, longestSide: CGFloat) -> NSImage? {
        let originalSize = image.size
        let maxSide = max(originalSize.width, originalSize.height)
        guard maxSide > longestSide else { return image }
        let scale = longestSide / maxSide
        let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    private static func jpegData(from image: NSImage, compression: CGFloat) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
#endif
}
