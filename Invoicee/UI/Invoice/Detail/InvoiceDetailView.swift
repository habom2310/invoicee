internal import SwiftUI
import UIKit

/// Shows detailed metadata for a captured invoice with editing actions.
///
/// Edits are made against `draft` and only written back to the archive on Save, so
/// abandoning the screen abandons the changes.
struct InvoiceDetailView: View {
    @Binding var invoice: CapturedInvoice
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var categoryStore: InvoiceCategoryStore
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @EnvironmentObject private var appEnvironment: AppEnvironment

    let onDelete: (CapturedInvoice) -> Void

    @State private var draft: CapturedInvoice
    @State private var newCategoryName = ""
    @State private var itemsExpanded = false
    @State private var isDownloadingAttachment = false
    @State private var downloadErrorMessage: String?
    @State private var isShowingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    init(invoice: Binding<CapturedInvoice>,
         onDelete: @escaping (CapturedInvoice) -> Void = { _ in }) {
        _invoice = invoice
        _draft = State(initialValue: invoice.wrappedValue)
        self.onDelete = onDelete
    }

    var body: some View {
        Form {
            Section("Invoice Info") {
                VStack(alignment: .leading, spacing: 16) {
                    // Split across three properties: a single `@ViewBuilder` block accepts
                    // at most ten children, and these fields total fifteen.
                    supplierAndAmountFields
                    categoryFields
                    dateAndMethodFields
                    attachment
                    if let deleteErrorMessage {
                        Text(deleteErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            itemsSection
        }
        .navigationTitle(draft.supplier.nilIfEmpty ?? "Invoice Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .disabled(isDeleting)
                .confirmationDialog("Delete invoice?",
                                    isPresented: $isShowingDeleteConfirmation,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteInvoice() }
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { saveChanges() }
                    .disabled(isDeleting)
            }
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private var supplierAndAmountFields: some View {
        InvoiceFieldLabel("Supplier")
        TextField("Supplier", text: $draft.supplier)
            .invoiceInputStyle()

        InvoiceFieldLabel("Total Amount")
        InvoiceCurrencyField("Total amount", text: .money($draft.total) { oldTotal, newTotal in
            // Our Amount was mirroring the total, so keep it in step; if the user had set
            // it to something else, leave their figure alone.
            if draft.ourAmount == oldTotal {
                draft.ourAmount = newTotal
            }
            draft.gst = GSTValidator.sanitizedAmount(for: draft.gst, total: newTotal) ?? .zero
        })

        InvoiceFieldLabel("Our Amount")
        InvoiceCurrencyField("Our amount", text: .money($draft.ourAmount))

        InvoiceFieldLabel("GST Amount")
        InvoiceCurrencyField("GST amount", text: .money($draft.gst) { _, entered in
            draft.gst = GSTValidator.sanitizedAmount(for: entered, total: draft.total) ?? .zero
        })

    }

    @ViewBuilder
    private var categoryFields: some View {
        InvoiceFieldLabel("Category")
        CategoryMenu(categories: categoryStore.categories, selection: draft.category) { category in
            draft.category = category
        }

        HStack {
            TextField("Add new category", text: $newCategoryName)
                .textInputAutocapitalization(.words)
            Button("Add") { addCategory() }
                .disabled(!canAddNewCategory)
        }
    }

    @ViewBuilder
    private var dateAndMethodFields: some View {
        InvoiceFieldLabel("Date")
        DatePicker("", selection: $draft.date, displayedComponents: .date)
            .labelsHidden()

        InvoiceFieldLabel("Capture Method")
        HStack(spacing: 8) {
            Image(systemName: draft.method.iconName)
            Text(draft.method.title)
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private var itemsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $itemsExpanded) {
                if draft.items.isEmpty {
                    Text("No items recorded.")
                        .foregroundStyle(.secondary)
                }

                ForEach($draft.items) { $item in
                    InvoiceItemFields(item: $item) {
                        draft.items.removeAll { $0.id == item.id }
                    }
                }

                Button {
                    draft.items.append(ManualInvoiceItem())
                } label: {
                    Label("Add Item", systemImage: "plus.circle")
                }
            } label: {
                HStack {
                    Text("Items [\(draft.items.count)]")
                        .font(.headline)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Attachment

    /// The remote file this invoice was uploaded as, preferring the PDF.
    private var remoteAttachment: (fileName: String, isPDF: Bool)? {
        if let pdf = draft.remotePDFFileName?.nilIfEmpty { return (pdf, true) }
        if let image = draft.remoteImageFileName?.nilIfEmpty { return (image, false) }
        return nil
    }

    @ViewBuilder
    private var attachment: some View {
        if let imageData = draft.imageData, let uiImage = UIImage(data: imageData) {
            VStack(alignment: .leading, spacing: 8) {
                InvoiceFieldLabel("Captured Image")
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let remote = remoteAttachment {
            VStack(alignment: .leading, spacing: 8) {
                InvoiceFieldLabel(remote.isPDF ? "Invoice PDF" : "Captured Image")
                Button {
                    downloadRemoteAttachment(named: remote.fileName, isPDF: remote.isPDF)
                } label: {
                    if isDownloadingAttachment {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(remote.isPDF ? "Download PDF from Google Drive" : "Download from Google Drive",
                              systemImage: remote.isPDF ? "arrow.down.doc" : "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloadingAttachment || isDeleting || driveConnector.state != .linked)

                if driveConnector.state != .linked, !isDownloadingAttachment {
                    Text("Link Google Drive to download the original file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let downloadErrorMessage {
                    Text(downloadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func downloadRemoteAttachment(named fileName: String, isPDF: Bool) {
        guard !isDownloadingAttachment, !isDeleting, driveConnector.state == .linked else { return }

        isDownloadingAttachment = true
        downloadErrorMessage = nil

        Task {
            defer { isDownloadingAttachment = false }
            do {
                let data = try await driveConnector.transferService
                    .downloadInvoiceImage(fileName: fileName, invoiceDate: draft.date)
                // A PDF needs rasterising for the inline preview; the render runs off the
                // main actor so a large page does not stall the screen.
                let previewData = isPDF ? try PDFPageRenderer.firstPageJPEG(of: data) : data

                draft.imageData = previewData
                if isPDF {
                    draft.pdfData = data
                    draft.remotePDFFileName = fileName
                } else {
                    draft.remoteImageFileName = fileName
                }

                // Persist the attachment without committing unsaved field edits: the user
                // asked to fetch a file, not to save the form.
                var stored = invoice
                stored.imageData = draft.imageData
                stored.pdfData = draft.pdfData
                stored.remoteImageFileName = draft.remoteImageFileName
                stored.remotePDFFileName = draft.remotePDFFileName
                invoice = stored
            } catch {
                downloadErrorMessage = error.userFacingDescription
            }
        }
    }

    // MARK: - Categories

    private var canAddNewCategory: Bool {
        guard let trimmed = newCategoryName.trimmed.nilIfEmpty else { return false }
        return !categoryStore.categories.containsIgnoringCase(trimmed)
    }

    private func addCategory() {
        guard let trimmed = newCategoryName.trimmed.nilIfEmpty else { return }
        categoryStore.addCategory(trimmed)
        draft.category = trimmed
        newCategoryName = ""
    }

    // MARK: - Save and delete

    private func saveChanges() {
        guard !isDeleting else { return }
        draft.lastEdited = Date()
        categoryStore.rememberCategory(draft.category, for: draft.supplier)
        invoice = draft
        dismiss()
    }

    private func deleteInvoice() async {
        isDeleting = true
        deleteErrorMessage = nil
        defer { isDeleting = false }

        let invoiceToDelete = invoice
        let tracker = appEnvironment.syncTracker
        let trackerRecord = await tracker.record(for: invoiceToDelete.id)

        // Fall back to the tracker's record when the invoice never learnt its remote name.
        let remoteFileNames = [
            invoiceToDelete.remoteImageFileName ?? Self.fileName(from: trackerRecord?.imagePath),
            invoiceToDelete.remotePDFFileName ?? Self.fileName(from: trackerRecord?.pdfPath)
        ]
        .compactMap { $0?.nilIfEmpty }

        do {
            // Refuse rather than orphan: deleting locally while the Drive copy survives
            // would leave a file the app can no longer see or clean up.
            if !remoteFileNames.isEmpty, driveConnector.state != .linked {
                throw InvoiceDeletionError.driveNotLinked
            }

            for fileName in remoteFileNames {
                try await driveConnector.transferService
                    .deleteInvoiceImage(fileName: fileName, invoiceDate: invoiceToDelete.date)
            }

            try await appEnvironment.firestoreUploader.delete(invoiceID: invoiceToDelete.id)
            await tracker.removeRecord(for: invoiceToDelete.id)

            onDelete(invoiceToDelete)
            dismiss()
        } catch {
            deleteErrorMessage = error.userFacingDescription
        }
    }

    private static func fileName(from path: String?) -> String? {
        path?.split(separator: "/").last.map(String.init)
    }

    private enum InvoiceDeletionError: LocalizedError {
        case driveNotLinked

        var errorDescription: String? {
            switch self {
            case .driveNotLinked: "Link Google Drive before deleting a synced invoice."
            }
        }
    }
}
