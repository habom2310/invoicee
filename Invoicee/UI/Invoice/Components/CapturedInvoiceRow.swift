import SwiftUI

/// Displays a single invoice summary inside the list.
struct CapturedInvoiceRow: View {
    var invoice: CapturedInvoice
    var isSynced: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSynced ? "icloud.fill" : "icloud.slash")
                .foregroundStyle(isSynced ? .blue : .secondary)
                .font(.title2)
                .padding(.top, 2)

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

                if invoice.gst > 0 {
                    Text("GST " + invoice.displayGST)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
