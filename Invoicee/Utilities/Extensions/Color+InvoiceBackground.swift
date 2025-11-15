internal import SwiftUI

/// Provides a consistent background colour for grouped invoice lists.
extension Color {
    static var invoiceBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
#elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
#else
        Color.gray.opacity(0.08)
#endif
    }
}
