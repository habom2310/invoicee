internal import SwiftUI

/// A small uppercase caption naming the field beneath it.
struct InvoiceFieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

/// A "$"-prefixed field that only accepts digits.
struct InvoiceCurrencyField: View {
    private let placeholder: String
    private let text: Binding<String>
    private let allowDecimal: Bool

    init(_ placeholder: String, text: Binding<String>, allowDecimal: Bool = true) {
        self.placeholder = placeholder
        self.text = text
        self.allowDecimal = allowDecimal
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "$")
                .foregroundStyle(.secondary)
            // No `textContentType`: these fields previously declared `.oneTimeCode`,
            // which made iOS offer SMS verification codes as autofill for an invoice
            // amount and suppressed the keyboard's own suggestions.
            TextField(placeholder, text: text.enforcingNumeric(allowDecimal: allowDecimal))
                .keyboardType(.decimalPad)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct InvoiceInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    /// The shared boxed appearance for editable invoice fields.
    func invoiceInputStyle() -> some View {
        modifier(InvoiceInputStyle())
    }
}
