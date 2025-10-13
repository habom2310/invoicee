import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shows detailed metadata for a captured invoice with editing actions.
struct InvoiceDetailView: View {
    @Binding var invoice: CapturedInvoice
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var categoryStore: InvoiceCategoryStore
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @EnvironmentObject private var appEnvironment: AppEnvironment
    let onDelete: (CapturedInvoice) -> Void
    @State private var draft: CapturedInvoice
    @State private var newCategoryName: String = ""
    @State private var itemsExpanded: Bool = false
    @State private var isDownloadingImage = false
    @State private var downloadErrorMessage: String? = nil
    @State private var isShowingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String? = nil

    init(invoice: Binding<CapturedInvoice>,
         onDelete: @escaping (CapturedInvoice) -> Void = { _ in }) {
        _invoice = invoice
        _draft = State(initialValue: invoice.wrappedValue)
        self.onDelete = onDelete
    }

    private var draftItemsBinding: Binding<[ManualInvoiceItem]> {
        Binding(
            get: { draft.items },
            set: { draft.items = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Invoice Info") {
                VStack(alignment: .leading, spacing: 16) {
                    InvoiceFieldLabel("Supplier")
                    TextField("Supplier", text: $draft.supplier)
                        .invoiceInputStyle()

                    InvoiceFieldLabel("Total Amount")
                    InvoiceCurrencyField("Total amount", text: totalAmountBinding)

                    InvoiceFieldLabel("Our Amount")
                    InvoiceCurrencyField("Our amount", text: ourAmountBinding)

                    InvoiceFieldLabel("GST Amount")
                    InvoiceCurrencyField("GST amount", text: gstAmountBinding)

                    InvoiceFieldLabel("Category")
                    Menu {
                        Button("None") { draft.category = nil }
                        ForEach(categoryStore.categories, id: \.self) { category in
                            Button(category) { draft.category = category }
                        }
                    } label: {
                        HStack {
                            Text(draft.category ?? "Select category")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    HStack {
                        TextField("Add new category", text: $newCategoryName)
                            .textInputAutocapitalization(.words)
                        Button("Add") {
                            addCategory()
                        }
                        .disabled(!canAddNewCategory)
                    }

                    InvoiceFieldLabel("Date")
                    DatePicker("", selection: $draft.date, displayedComponents: .date)
                        .labelsHidden()

                    InvoiceFieldLabel("Capture Method")
                    HStack(spacing: 8) {
                        Image(systemName: draft.method.iconName)
                            .foregroundStyle(.secondary)
                        Text(draft.method.title)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

#if canImport(UIKit)
                    if let imageData = draft.imageData, let uiImage = UIImage(data: imageData) {
                        capturedImagePreview(Image(uiImage: uiImage))
                    }
#elseif canImport(AppKit)
                    if let imageData = draft.imageData, let nsImage = NSImage(data: imageData) {
                        capturedImagePreview(Image(nsImage: nsImage))
                    }
#endif

                    if draft.imageData == nil,
                       draft.method == .camera,
                       let remoteFileName = draft.remoteImageFileName {
                        VStack(alignment: .leading, spacing: 8) {
                            InvoiceFieldLabel("Captured Image")
                            Button {
                                downloadRemoteImage(named: remoteFileName)
                            } label: {
                                if isDownloadingImage {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Label("Download from Google Drive", systemImage: "arrow.down.circle")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isDownloadingImage || driveConnector.state != .linked || isDeleting)

                            if driveConnector.state != .linked && !isDownloadingImage {
                                Text("Link Google Drive to download the original image.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            if let downloadErrorMessage {
                                Text(downloadErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }

                    if let deleteErrorMessage {
                        Text(deleteErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                DisclosureGroup(isExpanded: $itemsExpanded) {
                    if draft.items.isEmpty {
                        Text("No items recorded.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(draftItemsBinding) { $item in
                        InvoiceItemFields(item: $item) {
                            removeItem(withID: item.id)
                        }
                    }

                    Button {
                        addItem()
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
        .navigationTitle(draft.supplier.isEmpty ? "Invoice Details" : draft.supplier)
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
                .confirmationDialog("Delete invoice?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteInvoice() }
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveChanges()
                }
                .disabled(isDeleting)
            }
        }

        .onAppear {
            draft = invoice
        }
    }

    private func capturedImagePreview(_ image: Image) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InvoiceFieldLabel("Captured Image")
            image
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func addItem() {
        draft.items.append(ManualInvoiceItem())
    }

    private func removeItem(withID id: ManualInvoiceItem.ID) {
        var updatedItems = draftItemsBinding.wrappedValue
        updatedItems.removeAll { $0.id == id }
        draftItemsBinding.wrappedValue = updatedItems
    }

    private func saveChanges() {
        guard !isDeleting else { return }
        draft.lastEdited = Date()
        categoryStore.rememberCategory(draft.category, for: draft.supplier)
        invoice = draft
        dismiss()
    }

    private func downloadRemoteImage(named fileName: String) {
        guard !isDownloadingImage else { return }
        guard !isDeleting else { return }
        guard driveConnector.state == .linked else {
            downloadErrorMessage = "Google Drive is not linked."
            return
        }

        isDownloadingImage = true
        downloadErrorMessage = nil

        Task {
            do {
                let data = try await driveConnector.transferService.downloadInvoiceImage(fileName: fileName, invoiceDate: draft.date)
                await MainActor.run {
                    draft.imageData = data
                    draft.remoteImageFileName = fileName
                    invoice.imageData = data
                    invoice.remoteImageFileName = fileName
                    isDownloadingImage = false
                }
            } catch {
                await MainActor.run {
                    downloadErrorMessage = error.localizedDescription
                    isDownloadingImage = false
                }
            }
        }
    }

    private func deleteInvoice() async {
        await MainActor.run {
            isDeleting = true
            deleteErrorMessage = nil
        }

        let invoiceToDelete = await MainActor.run { invoice }
        var remoteFileName = await MainActor.run { invoice.remoteImageFileName }
        let invoiceDate = invoiceToDelete.date
        let tracker = appEnvironment.syncTracker
        if remoteFileName == nil {
            if let path = await tracker.record(for: invoiceToDelete.id)?.imagePath {
                remoteFileName = path.split(separator: "/").last.map(String.init)
            }
        }

        do {
            let driveState = await MainActor.run { driveConnector.state }

            if let remoteFileName, !remoteFileName.isEmpty, driveState != .linked {
                throw InvoiceDeletionError.driveNotLinked
            }

            if let remoteFileName, !remoteFileName.isEmpty, driveState == .linked {
                try await driveConnector.transferService.deleteInvoiceImage(fileName: remoteFileName, invoiceDate: invoiceDate)
            }

            try await appEnvironment.firestoreUploader.delete(invoiceID: invoiceToDelete.id)
            await tracker.removeRecord(for: invoiceToDelete.id)

            await MainActor.run {
                onDelete(invoiceToDelete)
                dismiss()
            }
        } catch {
            await MainActor.run {
                deleteErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        await MainActor.run {
            isDeleting = false
        }
    }

    private enum InvoiceDeletionError: LocalizedError {
        case driveNotLinked

        var errorDescription: String? {
            switch self {
            case .driveNotLinked:
                return "Link Google Drive before deleting a synced invoice."
            }
        }
    }

    private var canAddNewCategory: Bool {
        let trimmed = newCategoryName.trimmed
        guard !trimmed.isEmpty else { return false }
        return !categoryStore.categories.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func addCategory() {
        let trimmed = newCategoryName.trimmed
        guard !trimmed.isEmpty else { return }
        categoryStore.addCategory(trimmed)
        draft.category = trimmed
        newCategoryName = ""
    }

    private var totalAmountBinding: Binding<String> {
        Binding(
            get: { draft.total.plainString },
            set: { newValue in
                let filtered = newValue.filteredNumeric(allowDecimal: true)
                let previousTotal = draft.total
                draft.total = Decimal(string: filtered) ?? 0
                if draft.ourAmount == previousTotal {
                    draft.ourAmount = draft.total
                }
                let sanitizedGST = GSTValidator.sanitizedAmount(for: draft.gst, total: draft.total)
                draft.gst = sanitizedGST ?? 0
            }
        )
    }

    private var gstAmountBinding: Binding<String> {
        Binding(
            get: { draft.gst.plainString },
            set: { newValue in
                let filtered = newValue.filteredNumeric(allowDecimal: true)
                guard !filtered.isEmpty else {
                    draft.gst = 0
                    return
                }

                if let decimal = Decimal(string: filtered) {
                    draft.gst = GSTValidator.sanitizedAmount(for: decimal, total: draft.total) ?? 0
                } else {
                    draft.gst = 0
                }
            }
        )
    }

    private var ourAmountBinding: Binding<String> {
        Binding(
            get: { draft.ourAmount.plainString },
            set: { newValue in
                let filtered = newValue.filteredNumeric(allowDecimal: true)
                if filtered.isEmpty {
                    draft.ourAmount = draft.total
                } else {
                    draft.ourAmount = Decimal(string: filtered) ?? draft.total
                }
            }
        )
    }
}
