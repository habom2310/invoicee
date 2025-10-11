import SwiftUI
import Combine

struct ManualInvoiceFormView: View {
    @Binding var data: ManualInvoiceData
    @Binding var validationMessage: String?
    @ObservedObject var categoryStore: InvoiceCategoryStore
    @State private var itemsExpanded: Bool = false

    private var itemsBinding: Binding<[ManualInvoiceItem]> { $data.items }
    private var itemsValue: [ManualInvoiceItem] { itemsBinding.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            GroupBox("Supplier Details") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Supplier name", text: $data.supplier)
#if os(iOS)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
#endif
                        .invoiceInputStyle()

                    InvoiceFieldLabel("Total Amount")
                    InvoiceCurrencyField("Total amount", text: Binding(
                        get: { data.totalAmount?.plainString ?? "" },
                        set: { newValue in
                            let filtered = newValue.filteredNumeric(allowDecimal: true)
                            if filtered.isEmpty {
                                data.totalAmount = nil
                                if !data.hasCustomOurAmount {
                                    data.ourAmount = nil
                                }
                            } else if let decimal = Decimal(string: filtered) {
                                data.totalAmount = decimal
                                if !data.hasCustomOurAmount {
                                    data.ourAmount = nil
                                }
                            }

                            data.gstAmount = GSTValidator.sanitizedAmount(for: data.gstAmount, total: data.totalAmount)
                        }
                    ))

                    InvoiceFieldLabel("Our Amount")
                    InvoiceCurrencyField("Our amount", text: Binding(
                        get: {
                            if data.hasCustomOurAmount, let ourAmount = data.ourAmount {
                                return ourAmount.plainString
                            }
                            return data.totalAmount?.plainString ?? ""
                        },
                        set: { newValue in
                            let filtered = newValue.filteredNumeric(allowDecimal: true)
                            if filtered.isEmpty {
                                data.hasCustomOurAmount = false
                                data.ourAmount = nil
                            } else {
                                if let decimal = Decimal(string: filtered) {
                                    if let total = data.totalAmount, decimal == total {
                                        data.hasCustomOurAmount = false
                                        data.ourAmount = nil
                                    } else {
                                        data.hasCustomOurAmount = true
                                        data.ourAmount = decimal
                                    }
                                } else {
                                    data.hasCustomOurAmount = true
                                    data.ourAmount = nil
                                }
                            }
                        }
                    ))

                    InvoiceFieldLabel("GST Amount")
                    InvoiceCurrencyField("GST amount", text: Binding(
                        get: { data.gstAmount?.plainString ?? "" },
                        set: { newValue in
                            let filtered = newValue.filteredNumeric(allowDecimal: true)
                            guard !filtered.isEmpty else {
                                data.gstAmount = nil
                                return
                            }

                            if let decimal = Decimal(string: filtered) {
                                data.gstAmount = GSTValidator.sanitizedAmount(for: decimal, total: data.totalAmount)
                            } else {
                                data.gstAmount = nil
                            }
                        }
                    ))

                    VStack(alignment: .leading, spacing: 8) {
                        InvoiceFieldLabel("Category")
                        Menu {
                            Button("None") {
                                data.selectedCategory = nil
                                data.autoFilledSupplierKey = nil
                            }
                            ForEach(categoryStore.categories, id: \.self) { category in
                                Button(category) {
                                    data.selectedCategory = category
                                    data.autoFilledSupplierKey = nil
                                }
                            }
                        } label: {
                            HStack {
                                Text(data.selectedCategory ?? "Select category")
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

                        InvoiceFieldLabel("Add Category")
                        HStack {
                            TextField("Add new category", text: $data.newCategory)
                                .textInputAutocapitalization(.words)
                            Button("Add") {
                                addCategory()
                            }
                            .disabled(!canAddCategory)
                        }
                    }

                    DatePicker("Date", selection: $data.date, displayedComponents: .date)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                DisclosureGroup(isExpanded: $itemsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if itemsValue.isEmpty {
                            Text("No items added yet.")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(itemsBinding) { $item in
                            InvoiceItemFields(item: $item) {
                                removeItem(withID: item.id)
                            }

                            if item.id != itemsValue.last?.id {
                                Divider()
                            }
                        }

                        Button {
                            addItem()
                        } label: {
                            Label("Add Item", systemImage: "plus.circle")
                        }
                    }
                } label: {
                    HStack {
                        Text("Items [\(itemsValue.count)]")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            applyRememberedCategory(resetIfMissing: false)
        }
        .onChange(of: data.supplier) { _ in
            applyRememberedCategory(resetIfMissing: true)
        }
        .onReceive(categoryStore.$supplierCategories) { _ in
            applyRememberedCategory(resetIfMissing: false)
        }
        .onChange(of: data.items.count) { _ in
            if data.items.isEmpty {
                itemsExpanded = false
            }
        }
        .onAppear {
            itemsExpanded = false
        }
    }

    private var canAddCategory: Bool {
        let trimmed = data.newCategory.trimmed
        guard !trimmed.isEmpty else { return false }
        return !categoryStore.categories.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func addCategory() {
        let trimmed = data.newCategory.trimmed
        guard !trimmed.isEmpty else { return }
        categoryStore.addCategory(trimmed)
        data.selectedCategory = trimmed
        data.autoFilledSupplierKey = nil
        data.newCategory = ""
    }

    private func addItem() {
        var updatedItems = itemsBinding.wrappedValue
        updatedItems.append(ManualInvoiceItem())
        itemsBinding.wrappedValue = updatedItems
    }

    private func removeItem(withID id: ManualInvoiceItem.ID) {
        var updatedItems = itemsBinding.wrappedValue
        updatedItems.removeAll { $0.id == id }
        itemsBinding.wrappedValue = updatedItems
    }

    private func applyRememberedCategory(resetIfMissing: Bool) {
        let trimmedSupplier = data.supplier.trimmed

        guard !trimmedSupplier.isEmpty else {
            if resetIfMissing {
                data.selectedCategory = nil
                data.autoFilledSupplierKey = nil
            }
            return
        }

        if let rememberedCategory = categoryStore.category(for: trimmedSupplier) {
            let normalizedKey = trimmedSupplier.lowercased()
            if data.autoFilledSupplierKey == nil, data.selectedCategory != nil {
                return
            }

            if data.autoFilledSupplierKey != normalizedKey || data.selectedCategory != rememberedCategory {
                data.selectedCategory = rememberedCategory
                data.autoFilledSupplierKey = normalizedKey
            }
        } else if resetIfMissing {
            data.selectedCategory = nil
            data.autoFilledSupplierKey = nil
        }
    }

}

struct InvoiceItemFields: View {
    @Binding var item: ManualInvoiceItem
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InvoiceFieldLabel("Item Name")
            TextField("Item name", text: $item.name)

            InvoiceFieldLabel("Quantity & Unit Price")
            HStack {
                TextField("Quantity", text: $item.quantity.enforcingNumeric(allowDecimal: false))
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                TextField("Unit price", text: $item.unitPrice.enforcingNumeric(allowDecimal: true))
#if os(iOS)
                    .keyboardType(.decimalPad)
                    .textContentType(.oneTimeCode)
#endif
            }

            InvoiceFieldLabel("Item Amount")
            InvoiceCurrencyField("Item amount", text: $item.totalAmount)

            if let onDelete {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Remove Item", systemImage: "trash")
                    }
                }
            }
        }
    }

}
