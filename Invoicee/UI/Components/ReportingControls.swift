internal import SwiftUI

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
