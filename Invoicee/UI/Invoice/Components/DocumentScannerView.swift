#if canImport(VisionKit) && canImport(SwiftUI)
internal import SwiftUI
import VisionKit
#if canImport(UIKit)
import UIKit
#endif

/// Presents the system document scanner and reports the first scanned page.
///
/// A UI type, so it lives here rather than beside the OCR processor it feeds: `Services/`
/// has no business importing SwiftUI.
struct DocumentScannerView: UIViewControllerRepresentable {
    var completion: (Result<UIImage, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let completion: (Result<UIImage, Error>) -> Void

        init(completion: @escaping (Result<UIImage, Error>) -> Void) {
            self.completion = completion
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion(.failure(InvoiceOCRError.scanCancelled))
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(.failure(error))
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else {
                completion(.failure(InvoiceOCRError.invalidImage))
                return
            }
            completion(.success(scan.imageOfPage(at: 0)))
        }
    }
}
#endif
