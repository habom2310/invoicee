import SwiftUI

struct ManualInvoiceFormView: View {
    @Binding var data: ManualInvoiceData
    @Binding var validationMessage: String?
    @ObservedObject var categoryStore: InvoiceCategoryStore

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

                    fieldLabel("Total Amount")
                    currencyTextField(placeholder: "Total amount", value: Binding(
                        get: { data.totalAmount?.plainString ?? "" },
                        set: { newValue in
                            let filtered = newValue.filteredNumeric(allowDecimal: true)
                            data.totalAmount = filtered.isEmpty ? nil : Decimal(string: filtered)
                        }
                    ))

                    fieldLabel("GST Amount")
                    currencyTextField(placeholder: "GST amount", value: Binding(
                        get: { data.gstAmount?.plainString ?? "" },
                        set: { newValue in
                            let filtered = newValue.filteredNumeric(allowDecimal: true)
                            data.gstAmount = filtered.isEmpty ? nil : Decimal(string: filtered)
                        }
                    ))

                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Category")
                        Menu {
                            Button("None") { data.selectedCategory = nil }
                            ForEach(categoryStore.categories, id: \.self) { category in
                                Button(category) { data.selectedCategory = category }
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

                        fieldLabel("Add Category")
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

            GroupBox("Items") {
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
            }
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

    private func currencyTextField(placeholder: String, value: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text("$")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: value.enforcingNumeric(allowDecimal: true))
#if os(iOS)
                .keyboardType(.decimalPad)
                .textContentType(.oneTimeCode)
#endif
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

struct InvoiceItemFields: View {
    @Binding var item: ManualInvoiceItem
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("Item Name")
            TextField("Item name", text: $item.name)

            fieldLabel("Quantity & Unit Price")
            HStack {
                TextField("Quantity", text: $item.quantity.enforcingNumeric(allowDecimal: false))
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                TextField("Unit price", text: $item.unitPrice)
            }

            fieldLabel("Total Amount")
            currencyTextField(placeholder: "Total amount", value: $item.totalAmount)

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

    private func currencyTextField(placeholder: String, value: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text("$")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: value.enforcingNumeric(allowDecimal: true))
#if os(iOS)
                .keyboardType(.decimalPad)
                .textContentType(.oneTimeCode)
#endif
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}
