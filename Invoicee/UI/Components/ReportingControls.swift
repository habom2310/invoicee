internal import SwiftUI

/// A dropdown for picking a reporting year.
///
/// The expense, revenue, and profit tabs each had their own inline `Menu`/`Picker` for
/// this; two of them styled it differently for no reason anyone recorded.
struct YearMenuButton: View {
    @Binding var selection: Int
    let years: [Int]

    var body: some View {
        Menu {
            Picker("Year", selection: $selection) {
                ForEach(years, id: \.self) { year in
                    Text(verbatim: String(year)).tag(year)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                Text(verbatim: "Year \(selection)")
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reporting year")
    }
}

/// A list section that reports a problem, and disappears when there isn't one.
///
/// Every reporting tab repeated this block for export failures and load failures.
struct WarningSection: View {
    let message: String?

    init(_ message: String?) {
        self.message = message
    }

    var body: some View {
        if let message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}
