import SwiftUI

struct ExpenseTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "creditcard")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)

                Text("Expense tracking is coming soon.")
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.invoiceBackground)
            .navigationTitle("Expenses")
        }
    }
}
