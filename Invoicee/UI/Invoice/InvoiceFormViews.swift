internal import SwiftUI
import Combine

/// The shared supplier/amount/category/date form used for both manual entry and the
/// review step after a scan.
struct ManualInvoiceFormView: View {
    @Binding var data: ManualInvoiceData
    @Binding var validationMessage: String?
    @ObservedObject var categoryStore: InvoiceCategoryStore
    @State private var itemsExpanded = false

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
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .invoiceInputStyle()

                    amountFields
                    categoryFields

                    DatePicker("Date", selection: $data.date, displayedComponents: .date)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            itemsGroup
        }
        .onAppear {
            itemsExpanded = false
            applyRememberedCategory(resetIfMissing: false)
        }
        .onChange(of: data.supplier) { _, _ in
            applyRememberedCategory(resetIfMissing: true)
        }
        .onReceive(categoryStore.$supplierCategories) { _ in
            applyRememberedCategory(resetIfMissing: false)
        }
        .onChange(of: data.items.count) { _, newCount in
            if newCount == 0 {
                itemsExpanded = false
            }
        }
    }

    // MARK: - Amounts

    private var amountFields: some View {
        Group {
            InvoiceFieldLabel("Total Amount")
            InvoiceCurrencyField("Total amount", text: .optionalMoney($data.totalAmount) { _ in
                // Our Amount tracks the total until the user overrides it, and the GST
                // cap is a percentage of the total, so both react to a new total.
                if !data.hasCustomOurAmount {
                    data.ourAmount = nil
                }
                data.gstAmount = GSTValidator.sanitizedAmount(for: data.gstAmount, total: data.totalAmount)
            })

            InvoiceFieldLabel("Our Amount")
            InvoiceCurrencyField("Our amount", text: ourAmountBinding)

            InvoiceFieldLabel("GST Amount")
            InvoiceCurrencyField("GST amount", text: .optionalMoney($data.gstAmount) { entered in
                data.gstAmount = GSTValidator.sanitizedAmount(for: entered, total: data.totalAmount)
            })
        }
    }

    /// Shows the total until the user types something different; typing the total back in
    /// clears the override so the field resumes following it.
    private var ourAmountBinding: Binding<String> {
        .optionalMoney(Binding<Decimal?>(get: { data.hasCustomOurAmount ? data.ourAmount : nil },
                                        set: { data.ourAmount = $0 }),
                       placeholder: { data.totalAmount },
                       onChange: { entered in
                           guard let entered else {
                               data.hasCustomOurAmount = false
                               data.ourAmount = nil
                               return
                           }
                           data.hasCustomOurAmount = entered != data.totalAmount
                           data.ourAmount = data.hasCustomOurAmount ? entered : nil
                       })
    }

    // MARK: - Category

    private var categoryFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            InvoiceFieldLabel("Category")
            CategoryMenu(categories: categoryStore.categories,
                         selection: data.selectedCategory) { category in
                data.selectedCategory = category
                // The user chose deliberately, so stop treating it as auto-filled.
                data.autoFilledSupplierKey = nil
            }

            InvoiceFieldLabel("Add Category")
            HStack {
                TextField("Add new category", text: $data.newCategory)
                    .textInputAutocapitalization(.words)
                Button("Add") { addCategory() }
                    .disabled(!canAddCategory)
            }
        }
    }

    private var canAddCategory: Bool {
        guard let trimmed = data.newCategory.trimmed.nilIfEmpty else { return false }
        return !categoryStore.categories.containsIgnoringCase(trimmed)
    }

    private func addCategory() {
        guard let trimmed = data.newCategory.trimmed.nilIfEmpty else { return }
        categoryStore.addCategory(trimmed)
        data.selectedCategory = trimmed
        data.autoFilledSupplierKey = nil
        data.newCategory = ""
    }

    /// Fills the category from the supplier's remembered choice.
    ///
    /// - Parameter resetIfMissing: clear the selection when the supplier has no
    ///   remembered category. Set when the supplier changed (the old supplier's category
    ///   should not stick), clear when only the remembered mapping changed.
    private func applyRememberedCategory(resetIfMissing: Bool) {
        func reset() {
            data.selectedCategory = nil
            data.autoFilledSupplierKey = nil
        }

        guard let supplier = data.supplier.trimmed.nilIfEmpty else {
            if resetIfMissing { reset() }
            return
        }

        guard let remembered = categoryStore.category(for: supplier) else {
            if resetIfMissing { reset() }
            return
        }

        // Never overwrite a category the user picked by hand.
        let isUserChosen = data.autoFilledSupplierKey == nil && data.selectedCategory != nil
        guard !isUserChosen else { return }

        let key = supplier.lowercased()
        guard data.autoFilledSupplierKey != key || data.selectedCategory != remembered else { return }
        data.selectedCategory = remembered
        data.autoFilledSupplierKey = key
    }

    // MARK: - Items

    private var itemsGroup: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $itemsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if data.items.isEmpty {
                        Text("No items added yet.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($data.items) { $item in
                        InvoiceItemFields(item: $item) {
                            data.items.removeAll { $0.id == item.id }
                        }

                        if item.id != data.items.last?.id {
                            Divider()
                        }
                    }

                    Button {
                        data.items.append(ManualInvoiceItem())
                    } label: {
                        Label("Add Item", systemImage: "plus.circle")
                    }
                }
            } label: {
                HStack {
                    Text("Items [\(data.items.count)]")
                        .font(.headline)
                    Spacer()
                }
            }
        }
    }
}

/// A dropdown of known categories, plus "None".
struct CategoryMenu: View {
    let categories: [String]
    let selection: String?
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            Button("None") { onSelect(nil) }
            ForEach(categories, id: \.self) { category in
                Button(category) { onSelect(category) }
            }
        } label: {
            HStack {
                Text(selection ?? "Select category")
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .invoiceInputStyle()
        }
        .accessibilityLabel("Invoice category")
    }
}

struct InvoiceItemFields: View {
    @Binding var item: ManualInvoiceItem
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InvoiceFieldLabel("Item Name")
            TextField("Item name", text: $item.name)

            InvoiceFieldLabel("Quantity & Unit Price")
            HStack {
                TextField("Quantity", text: $item.quantity.enforcingNumeric(allowDecimal: false))
                    .keyboardType(.numberPad)
                TextField("Unit price", text: $item.unitPrice.enforcingNumeric(allowDecimal: true))
                    .keyboardType(.decimalPad)
            }

            InvoiceFieldLabel("Item Amount")
            InvoiceCurrencyField("Item amount", text: $item.totalAmount)

            if let onDelete {
                HStack {
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Label("Remove Item", systemImage: "trash")
                    }
                }
            }
        }
    }
}
