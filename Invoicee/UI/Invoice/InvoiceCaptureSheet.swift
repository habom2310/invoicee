internal import SwiftUI
import UIKit

/// Handles camera/manual entry for capturing a new invoice.
struct InvoiceCaptureSheet: View {
    @ObservedObject private var categoryStore: InvoiceCategoryStore
    @Binding var isPresented: Bool
    let knownSuppliers: [String]
    let onSubmit: (CapturedInvoice) -> Void

    init(categoryStore: InvoiceCategoryStore,
         knownSuppliers: [String] = [],
         isPresented: Binding<Bool>,
         onSubmit: @escaping (CapturedInvoice) -> Void) {
        _categoryStore = ObservedObject(wrappedValue: categoryStore)
        _isPresented = isPresented
        // De-duplicated once here: OCR matches every scanned line against this list.
        self.knownSuppliers = Self.distinctSuppliers(knownSuppliers)
        self.onSubmit = onSubmit
    }

    private enum CaptureMode {
        case camera
        case manual

        var toggleLabel: String {
            switch self {
            case .camera: "Manual Input"
            case .manual: "Use Camera"
            }
        }

        var toggled: CaptureMode {
            self == .camera ? .manual : .camera
        }
    }

    /// Which picker, if any, is on screen. One value instead of three independent
    /// booleans, so two pickers can never be presented at once.
    private enum ActivePicker: Identifiable {
        case documentScanner
        case photoLibrary
        case pdfFile

        var id: Self { self }
    }

    @State private var captureMode: CaptureMode = .camera
    @State private var manualData = ManualInvoiceData()
    @State private var manualValidationMessage: String?

    @State private var isProcessing = false
    @State private var ocrData = ManualInvoiceData()
    @State private var hasOCRResult = false
    @State private var ocrValidationMessage: String?
    @State private var ocrErrorMessage: String?
    @State private var capturedImage: UIImage?
    @State private var capturedPDFData: Data?
    @State private var activePicker: ActivePicker?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch captureMode {
                case .camera: cameraContent
                case .manual: manualContent
                }
            }
            .padding()
            .background(Color.invoiceBackground)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                    }
                    .accessibilityLabel("Cancel")
                }

                ToolbarItem(placement: .principal) {
                    Text("Add Invoice")
                        .font(.headline)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if hasOCRResult {
                        Button("Save") { saveRecognizedInvoice() }
                            .disabled(isProcessing)
                    } else {
                        Button(captureMode.toggleLabel) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                captureMode = captureMode.toggled
                                resetCaptureState()
                                manualValidationMessage = nil
                            }
                        }
                        .disabled(isProcessing)
                    }
                }
            }
        }
        .sheet(item: $activePicker) { picker in
            switch picker {
            case .documentScanner:
                DocumentScannerView { handleImageResult($0) }
            case .photoLibrary:
                PhotoLibraryPicker { handleImageResult($0) }
            case .pdfFile:
                PDFDocumentPicker { handlePDFResult($0) }
            }
        }
    }

    // MARK: - Camera flow

    private var cameraContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !hasOCRResult {
                    Text("Capture an invoice with the camera, import a PDF, or pick an existing photo. Review and edit the detected details before saving.")
                        .foregroundStyle(.secondary)
                }

                if let capturedImage {
                    GroupBox("Latest Scan") {
                        Image(uiImage: capturedImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                captureActions

                if isProcessing {
                    ProgressView("Extracting invoice details…")
                }

                if let ocrErrorMessage {
                    Text(ocrErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if hasOCRResult {
                    ManualInvoiceFormView(data: $ocrData,
                                          validationMessage: $ocrValidationMessage,
                                          categoryStore: categoryStore)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureActions: some View {
        HStack(spacing: 20) {
            Spacer()

            captureButton(systemImage: "photo.on.rectangle",
                          size: 28,
                          label: "Select invoice from photos",
                          prominent: false) {
                activePicker = .photoLibrary
            }

            captureButton(systemImage: hasOCRResult ? "camera.rotate" : "camera",
                          size: 36,
                          label: hasOCRResult ? "Rescan invoice" : "Scan invoice",
                          prominent: true) {
                ocrErrorMessage = nil
                hasOCRResult = false
                activePicker = .documentScanner
            }

            captureButton(systemImage: "doc.richtext",
                          size: 30,
                          label: "Import invoice PDF",
                          prominent: false) {
                activePicker = .pdfFile
            }

            if hasOCRResult {
                captureButton(systemImage: "trash",
                              size: 22,
                              label: "Clear scanned invoice",
                              prominent: false) {
                    resetCaptureState()
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func captureButton(systemImage: String,
                               size: CGFloat,
                               label: String,
                               prominent: Bool,
                               action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var manualContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ManualInvoiceFormView(data: $manualData,
                                      validationMessage: $manualValidationMessage,
                                      categoryStore: categoryStore)

                Button("Save Invoice") { saveManualInvoice() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)
            }
        }
    }

    // MARK: - Picker results

    private func handleImageResult(_ result: Result<UIImage, Error>) {
        // Clearing this is what dismisses the picker. The photo library branch used to
        // rely on its coordinator calling `dismiss` on the controller instead, which left
        // the presentation flag set — so the button worked exactly once per sheet.
        activePicker = nil

        switch result {
        case .success(let image):
            capturedImage = image
            capturedPDFData = nil
            extractInvoiceData(from: image)
        case .failure(let error):
            // `reportableDescription` is nil for a cancelled picker, which is not a
            // failure worth putting on screen.
            ocrErrorMessage = error.reportableDescription
        }
    }

    private func handlePDFResult(_ result: Result<URL, Error>) {
        activePicker = nil

        switch result {
        case .success(let url):
            processPDF(at: url)
        case .failure(let error):
            ocrErrorMessage = error.reportableDescription
        }
    }

    private func processPDF(at url: URL) {
        ocrErrorMessage = nil
        hasOCRResult = false
        isProcessing = true

        Task {
            do {
                let loaded = try await Self.loadPDF(at: url)
                capturedPDFData = loaded.data
                capturedImage = loaded.preview
                extractInvoiceData(from: loaded.preview)
            } catch {
                capturedPDFData = nil
                ocrErrorMessage = error.userFacingDescription
                isProcessing = false
            }
        }
    }

    /// Reads the security-scoped file the document picker handed over and rasterises its
    /// first page.
    ///
    /// `nonisolated` so both the file read and the render happen off the main actor —
    /// they used to run inside a main-actor `Task`, freezing the sheet for as long as the
    /// page took to draw.
    private nonisolated static func loadPDF(at url: URL) async throws -> (data: Data, preview: UIImage) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        return (data, try PDFPageRenderer.firstPageImage(of: data))
    }

    private func extractInvoiceData(from image: UIImage) {
        isProcessing = true
        ocrErrorMessage = nil
        hasOCRResult = false

        Task {
            defer { isProcessing = false }
            do {
                ocrData = try await InvoiceOCRProcessor.process(image: image,
                                                               knownSuppliers: knownSuppliers)
                hasOCRResult = true
            } catch {
                ocrErrorMessage = error.userFacingDescription
            }
        }
    }

    // MARK: - Saving

    private func saveManualInvoice() {
        manualValidationMessage = nil
        guard manualData.isValid else {
            manualValidationMessage = Self.validationMessage
            return
        }
        submit(manualData, method: .manual, imageData: nil, pdfData: nil)
    }

    private func saveRecognizedInvoice() {
        ocrValidationMessage = nil
        guard ocrData.isValid else {
            ocrValidationMessage = Self.validationMessage
            return
        }
        submit(ocrData,
               method: .camera,
               imageData: capturedImage?.jpegData(compressionQuality: 0.85),
               pdfData: capturedPDFData)
    }

    private static let validationMessage = "A supplier and total amount are required before saving."

    private func submit(_ data: ManualInvoiceData,
                        method: CapturedInvoice.Method,
                        imageData: Data?,
                        pdfData: Data?) {
        guard let total = data.totalAmount else { return }

        let invoice = CapturedInvoice(
            supplier: data.supplier.trimmed,
            total: total,
            // An unset Our Amount means "same as the total".
            ourAmount: data.hasCustomOurAmount ? (data.ourAmount ?? total) : total,
            gst: GSTValidator.sanitizedAmount(for: data.gstAmount, total: total) ?? .zero,
            date: data.date,
            method: method,
            category: data.selectedCategory,
            items: data.items,
            imageData: imageData,
            pdfData: pdfData,
            remoteImageFileName: nil,
            remotePDFFileName: nil,
            lastEdited: Date()
        )

        categoryStore.rememberCategory(invoice.category, for: invoice.supplier)
        onSubmit(invoice)
        isPresented = false
    }

    private func resetCaptureState() {
        isProcessing = false
        hasOCRResult = false
        ocrData = ManualInvoiceData()
        ocrValidationMessage = nil
        ocrErrorMessage = nil
        capturedImage = nil
        capturedPDFData = nil
    }

    private static func distinctSuppliers(_ suppliers: [String]) -> [String] {
        var unique: [String] = []
        for supplier in suppliers {
            guard let trimmed = supplier.trimmed.nilIfEmpty,
                  !unique.containsIgnoringCase(trimmed) else { continue }
            unique.append(trimmed)
        }
        return unique
    }
}
