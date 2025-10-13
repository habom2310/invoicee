import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Handles camera/manual entry for capturing a new invoice.
struct InvoiceCaptureSheet: View {
    @ObservedObject private var categoryStore: InvoiceCategoryStore
    @Binding var isPresented: Bool
    var onSubmit: (CapturedInvoice) -> Void

    init(categoryStore: InvoiceCategoryStore,
         knownSuppliers: [String] = [],
         isPresented: Binding<Bool>,
         onSubmit: @escaping (CapturedInvoice) -> Void) {
        self._categoryStore = ObservedObject(wrappedValue: categoryStore)
        self._knownSuppliers = State(initialValue: InvoiceCaptureSheet.normalizeSuppliers(knownSuppliers))
        self._isPresented = isPresented
        self.onSubmit = onSubmit
    }

    @State private var captureMode: CaptureMode = .camera
    @State private var manualData = ManualInvoiceData()
    @State private var manualValidationMessage: String?

    @State private var isProcessing = false
    @State private var ocrData = ManualInvoiceData()
    @State private var hasOCRResult = false
    @State private var ocrValidationMessage: String?
    @State private var ocrErrorMessage: String?
    @State private var knownSuppliers: [String]

#if canImport(VisionKit)
    @State private var scannedImage: UIImage?
    @State private var scannedThumbnail: Image?
    @State private var isPresentingDocumentScanner = false
    @State private var isPresentingPhotoPicker = false
#endif

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch captureMode {
                case .camera:
                    cameraContent
                case .manual:
                    manualContent
                }
            }
            .padding()
            .background(Color.invoiceBackground)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissSheet()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                    }
                }

                ToolbarItem(placement: .principal) {
                    HStack {
                        Spacer(minLength: 0)
                        Text("Add Invoice")
                            .font(.headline)
                        Spacer(minLength: 0)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(captureMode.toggleLabel) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            captureMode.toggle()
                            resetCameraState()
                            manualValidationMessage = nil
                        }
                    }
                    .disabled(isProcessing)
                }
            }
        }
#if canImport(VisionKit)
        .sheet(isPresented: $isPresentingDocumentScanner) {
            DocumentScannerView { result in
                handleScanResult(result)
            }
        }
        .sheet(isPresented: $isPresentingPhotoPicker) {
            PhotoLibraryPicker { result in
                handlePhotoLibraryResult(result)
            }
        }
#endif
    }

    private var cameraContent: some View {
#if canImport(VisionKit)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !hasOCRResult {
                    Text("Capture an invoice with the camera or pick an existing photo. Review and edit the detected details before saving.")
                        .foregroundStyle(.secondary)
                }

                if let scannedThumbnail {
                    GroupBox("Latest Scan") {
                        scannedThumbnail
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                HStack(spacing: 20) {
                    Spacer()

                    Button {
                        startScan()
                    } label: {
                        Image(systemName: hasOCRResult ? "camera.rotate" : "camera")
                            .font(.system(size: 36, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
#if os(iOS)
                    .buttonBorderShape(.circle)
#endif
                    .accessibilityLabel(hasOCRResult ? "Rescan invoice" : "Scan invoice")

                    Button {
                        isPresentingPhotoPicker = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 28, weight: .medium))
                    }
                    .buttonStyle(.bordered)
#if os(iOS)
                    .buttonBorderShape(.circle)
#endif
                    .accessibilityLabel("Select invoice from photos")

                    if hasOCRResult {
                        Button {
                            resetCameraState()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 22, weight: .regular))
                        }
                        .buttonStyle(.bordered)
#if os(iOS)
                        .buttonBorderShape(.circle)
#endif
                        .accessibilityLabel("Clear scanned invoice")
                    }

                    Spacer()
                }

                if isProcessing {
                    ProgressView("Extracting invoice details…")
                }

                if let ocrErrorMessage {
                    Text(ocrErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if hasOCRResult {
                    ManualInvoiceFormView(data: $ocrData, validationMessage: $ocrValidationMessage, categoryStore: categoryStore)

                    Button("Save") {
                        saveRecognizedInvoice()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
#else
        VStack(spacing: 16) {
            Text("Invoice scanning is available on iOS devices only. Switch to Manual Entry to add details.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
#endif
    }

    private var manualContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ManualInvoiceFormView(data: $manualData, validationMessage: $manualValidationMessage, categoryStore: categoryStore)

                Button("Save Invoice") {
                    saveManualInvoice()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)
            }
        }
    }

    private func saveManualInvoice() {
        manualValidationMessage = nil

        guard manualData.isValid else {
            manualValidationMessage = "Supplier, total amount, and date are required before saving."
            return
        }

        finalizeSubmission(from: manualData, method: .manual, imageData: nil)
    }

    private func saveRecognizedInvoice() {
        ocrValidationMessage = nil

        guard ocrData.isValid else {
            ocrValidationMessage = "Supplier, total amount, and date are required before saving."
            return
        }

        var capturedImageData: Data?
#if canImport(UIKit)
        if let scannedImage {
            capturedImageData = scannedImage.jpegData(compressionQuality: 0.85)
        }
#endif

        finalizeSubmission(from: ocrData, method: .camera, imageData: capturedImageData)
    }

    private func finalizeSubmission(from data: ManualInvoiceData, method: CapturedInvoice.Method, imageData: Data?) {
        guard let totalDecimal = data.totalAmount else { return }
        let sanitizedGST = GSTValidator.sanitizedAmount(for: data.gstAmount, total: data.totalAmount)
        let gstDecimal = sanitizedGST ?? 0
        let ourAmount = data.hasCustomOurAmount ? (data.ourAmount ?? totalDecimal) : totalDecimal

        let now = Date()
        let invoice = CapturedInvoice(
            supplier: data.supplier.trimmed,
            total: totalDecimal,
            ourAmount: ourAmount,
            gst: gstDecimal,
            date: data.date,
            method: method,
            category: data.selectedCategory,
            items: data.items,
            imageData: imageData,
            remoteImageFileName: nil,
            lastEdited: now
        )

        categoryStore.rememberCategory(invoice.category, for: invoice.supplier)
        appendKnownSupplier(invoice.supplier)
        onSubmit(invoice)
        resetCameraState()
        manualData = ManualInvoiceData()
        manualValidationMessage = nil
        dismissSheet()
    }

    private func dismissSheet() {
        isPresented = false
    }

    private func resetCameraState() {
        isProcessing = false
        hasOCRResult = false
        ocrData = ManualInvoiceData()
        ocrValidationMessage = nil
        ocrErrorMessage = nil
#if canImport(VisionKit)
        scannedImage = nil
        scannedThumbnail = nil
#endif
    }

    private static func normalizeSuppliers(_ suppliers: [String]) -> [String] {
        var unique: [String] = []
        for supplier in suppliers {
            let trimmed = supplier.trimmed
            guard !trimmed.isEmpty else { continue }
            if !unique.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                unique.append(trimmed)
            }
        }
        return unique
    }

    private func appendKnownSupplier(_ supplier: String) {
        let trimmed = supplier.trimmed
        guard !trimmed.isEmpty else { return }
        if !knownSuppliers.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            knownSuppliers.append(trimmed)
        }
    }

#if canImport(VisionKit)
    private func startScan() {
        ocrErrorMessage = nil
        hasOCRResult = false
        isPresentingDocumentScanner = true
    }

    private func handleScanResult(_ result: Result<UIImage, Error>) {
        isPresentingDocumentScanner = false

        switch result {
        case .success(let image):
            scannedImage = image
            scannedThumbnail = Image(uiImage: image)
            extractInvoiceData(from: image)
        case .failure(let error):
            ocrErrorMessage = error.localizedDescription
        }
    }

    private func handlePhotoLibraryResult(_ result: Result<UIImage, Error>) {
        switch result {
        case .success(let image):
            scannedImage = image
            scannedThumbnail = Image(uiImage: image)
            extractInvoiceData(from: image)
        case .failure(let error):
            if let pickerError = error as? PhotoLibraryPicker.PickerError, pickerError == .cancelled {
                return
            }
            ocrErrorMessage = error.localizedDescription
        }
    }

    private func extractInvoiceData(from image: UIImage) {
        isProcessing = true
        ocrErrorMessage = nil
        hasOCRResult = false

        Task {
            do {
                let supplierSnapshot = knownSuppliers
                let result = try await InvoiceOCRProcessor.process(image: image, knownSuppliers: supplierSnapshot)
                await MainActor.run {
                    ocrData = result.data
                    hasOCRResult = true
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    ocrErrorMessage = error.localizedDescription
                    isProcessing = false
                }
            }
        }
    }
#endif
}

extension InvoiceCaptureSheet {
    enum CaptureMode {
        case camera
        case manual

        var toggleLabel: String {
            switch self {
            case .camera: "Manual Input"
            case .manual: "Use Camera"
            }
        }

        mutating func toggle() {
            self = self == .camera ? .manual : .camera
        }
    }
}

#if canImport(UIKit)
private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIImagePickerController
    let onComplete: (Result<UIImage, Error>) -> Void

    enum PickerError: LocalizedError, Equatable {
        case cancelled
        case missingImage

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return nil
            case .missingImage:
                return "Unable to load selected image."
            }
        }
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: PhotoLibraryPicker

        init(parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onComplete(.failure(PickerError.cancelled))
            picker.dismiss(animated: true)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            defer { picker.dismiss(animated: true) }

            let edited = info[.editedImage] as? UIImage
            let original = info[.originalImage] as? UIImage

            if let image = edited ?? original {
                parent.onComplete(.success(image))
            } else {
                parent.onComplete(.failure(PickerError.missingImage))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}
#endif
