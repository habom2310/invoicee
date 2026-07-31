import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum PDFRenderError: LocalizedError {
    case invalidDocument
    case renderFailed
    case unsupported

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "Unable to read the PDF."
        case .renderFailed: "Unable to render a preview for the PDF."
        case .unsupported: "PDF preview is not supported on this device."
        }
    }
}

/// Rasterises the first page of a PDF, for preview and for feeding OCR.
///
/// Both the capture sheet and the invoice detail view had their own copy of this
/// (flip-the-context, fill-white, draw-the-page) and both sized the bitmap at
/// `UIScreen.main.scale * 2`. That was two problems: `UIScreen.main` is main-actor
/// bound, which forced the whole rasterise onto the main thread, and an A3 page on a
/// 3x device produced a ~90 MB bitmap. The scale is now derived from the page and
/// capped, and nothing here touches the main actor.
nonisolated enum PDFPageRenderer {
    /// Cap on the rendered bitmap's longest side, in pixels.
    ///
    /// High enough that small print still OCRs (roughly 290 dpi on A4), low enough that
    /// a single page stays around 16 MB rather than growing with the page's dimensions.
    private static let maximumLongestSide: CGFloat = 2400

    /// Renders the first page as JPEG data.
    static func firstPageJPEG(of data: Data, compressionQuality: CGFloat = 0.85) throws -> Data {
#if canImport(PDFKit) && canImport(UIKit)
        guard let jpeg = try firstPageImage(of: data).jpegData(compressionQuality: compressionQuality) else {
            throw PDFRenderError.renderFailed
        }
        return jpeg
#else
        throw PDFRenderError.unsupported
#endif
    }

#if canImport(PDFKit) && canImport(UIKit)
    /// Renders the first page as an image.
    static func firstPageImage(of data: Data) throws -> UIImage {
        guard let page = PDFDocument(data: data)?.page(at: 0) else {
            throw PDFRenderError.invalidDocument
        }

        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else {
            throw PDFRenderError.invalidDocument
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale(for: pageRect.size)
        format.opaque = true

        return UIGraphicsImageRenderer(size: pageRect.size, format: format).image { context in
            // PDFs are drawn bottom-up, so fill an opaque background and flip the
            // context before handing it to PDFKit.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pageRect.size))
            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pageRect.size.height)
            cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }
    }

    /// Upscales small pages for legibility but never past `maximumLongestSide`.
    private static func renderScale(for size: CGSize) -> CGFloat {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else { return 1 }
        return min(3, max(1, maximumLongestSide / longestSide))
    }
#endif
}
