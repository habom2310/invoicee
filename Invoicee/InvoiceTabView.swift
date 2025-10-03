import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct InvoiceTabView: View {
    @ObservedObject private var categoryStore = InvoiceCategoryStore.shared
    @State private var isPresentingCaptureSheet = false
    @State private var invoices: [CapturedInvoice] = []

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    VStack(spacing: 24) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 68))
                            .foregroundStyle(.blue)

                        Text("Capture your invoices or enter details manually to prepare them for processing.")
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.invoiceBackground)
                } else {
                    List {
                        Section("Invoices") {
                            ForEach($invoices) { $invoice in
                                NavigationLink {
                                    InvoiceDetailView(invoice: $invoice, categoryStore: categoryStore)
                                } label: {
                                    CapturedInvoiceRow(invoice: invoice)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Invoices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresentingCaptureSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Invoice")
                }
            }
            .sheet(isPresented: $isPresentingCaptureSheet) {
                InvoiceCaptureSheet(categoryStore: categoryStore, isPresented: $isPresentingCaptureSheet) { invoice in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        invoices.insert(invoice, at: 0)
                    }
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(true)
            }
        }
    }
}

struct CapturedInvoiceRow: View {
    var invoice: CapturedInvoice

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(invoice.supplier.isEmpty ? "Unnamed Supplier" : invoice.supplier)
                    .font(.headline)

                HStack(spacing: 8) {
                    Image(systemName: invoice.method.iconName)
                        .foregroundStyle(.secondary)
                    Text(invoice.method.title)
                    Text(invoice.formattedDate)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(invoice.displayTotal)
                    .font(.headline)

                if let category = invoice.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct InvoiceDetailView: View {
    @Binding var invoice: CapturedInvoice
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var categoryStore: InvoiceCategoryStore
    @State private var draft: CapturedInvoice
    @State private var newCategoryName: String = ""

    init(invoice: Binding<CapturedInvoice>, categoryStore: InvoiceCategoryStore = .shared) {
        _invoice = invoice
        _categoryStore = ObservedObject(wrappedValue: categoryStore)
        _draft = State(initialValue: invoice.wrappedValue)
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
                    fieldLabel("Supplier")
                    TextField("Supplier", text: $draft.supplier)

                    fieldLabel("Total Amount")
                    TextField("Total amount", text: $draft.total.enforcingNumeric(allowDecimal: true))
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif

                    fieldLabel("Category")
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

                    fieldLabel("Date")
                    DatePicker("", selection: $draft.date, displayedComponents: .date)
                        .labelsHidden()

                    fieldLabel("Capture Method")
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Items") {
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
            }
        }
        .navigationTitle(draft.supplier.isEmpty ? "Invoice Details" : draft.supplier)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveChanges()
                }
                .bold()
            }
        }
        .onAppear {
            draft = invoice
        }
    }

    private func capturedImagePreview(_ image: Image) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Captured Image")
            image
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private func addItem() {
        var updatedItems = draftItemsBinding.wrappedValue
        updatedItems.append(ManualInvoiceItem())
        draftItemsBinding.wrappedValue = updatedItems
    }

    private func removeItem(withID id: ManualInvoiceItem.ID) {
        var updatedItems = draftItemsBinding.wrappedValue
        updatedItems.removeAll { $0.id == id }
        draftItemsBinding.wrappedValue = updatedItems
    }

    private func cancelChanges() {
        draft = invoice
        dismiss()
    }

    private func saveChanges() {
        invoice = draft
        dismiss()
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
}
