internal import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Cancelling a picker surfaces as a failure with no message, so the caller can tell it
/// from a real error without a type check.
private enum PickerError: LocalizedError {
    case cancelled
    case missingImage
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .missingImage: "Unable to load the selected image."
        case .invalidSelection: "Unable to load the selected PDF."
        }
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onComplete: (Result<UIImage, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onComplete: (Result<UIImage, Error>) -> Void

        init(onComplete: @escaping (Result<UIImage, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onComplete(.failure(PickerError.cancelled))
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // `allowsEditing` is off, so only `.originalImage` is ever populated.
            guard let image = info[.originalImage] as? UIImage else {
                onComplete(.failure(PickerError.missingImage))
                return
            }
            onComplete(.success(image))
        }
    }
}

struct PDFDocumentPicker: UIViewControllerRepresentable {
    let onComplete: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Result<URL, Error>) -> Void

        init(onComplete: @escaping (Result<URL, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(.failure(PickerError.cancelled))
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onComplete(.failure(PickerError.invalidSelection))
                return
            }
            onComplete(.success(url))
        }
    }
}
