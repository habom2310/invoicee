internal import SwiftUI

struct InvoiceFieldLabel: View {
    var text: String

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
            Text("$")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text.enforcingNumeric(allowDecimal: allowDecimal))
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
    func invoiceInputStyle() -> some View {
        modifier(InvoiceInputStyle())
    }
}
