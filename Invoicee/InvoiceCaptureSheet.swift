import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct InvoiceCaptureSheet: View {
    @ObservedObject private var categoryStore: InvoiceCategoryStore
    @Binding var isPresented: Bool
    var onSubmit: (CapturedInvoice) -> Void

    init(categoryStore: InvoiceCategoryStore = .shared,
         isPresented: Binding<Bool>,
         onSubmit: @escaping (CapturedInvoice) -> Void) {
        self._categoryStore = ObservedObject(wrappedValue: categoryStore)
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
    @State private var ocrRawLines: [String] = []
    @State private var ocrErrorMessage: String?

#if canImport(VisionKit)
    @State private var scannedImage: UIImage?
    @State private var scannedThumbnail: Image?
    @State private var isPresentingDocumentScanner = false
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
#endif
    }

    private var cameraContent: some View {
#if canImport(VisionKit)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !hasOCRResult {
                    Text("Tap the camera icon to scan an invoice. Review and edit the detected details before saving.")
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
        let invoice = CapturedInvoice(
            supplier: data.supplier.trimmed,
            total: data.totalAmount.trimmed,
            date: data.date,
            method: method,
            category: data.selectedCategory,
            items: data.items,
            imageData: imageData
        )

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
        ocrRawLines = []
        ocrErrorMessage = nil
#if canImport(VisionKit)
        scannedImage = nil
        scannedThumbnail = nil
#endif
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

    private func extractInvoiceData(from image: UIImage) {
        isProcessing = true
        ocrErrorMessage = nil
        ocrRawLines = []
        hasOCRResult = false

        Task {
            do {
                let result = try await InvoiceOCRProcessor.process(image: image)
                await MainActor.run {
                    ocrData = result.data
                    ocrRawLines = result.rawLines
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
