import SwiftUI

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

extension Binding where Value == String {
    func enforcingNumeric(allowDecimal: Bool) -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue.filteredNumeric(allowDecimal: allowDecimal)
            }
        )
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func filteredNumeric(allowDecimal: Bool) -> String {
        var result = ""
        var hasDecimalSeparator = false

        for character in self {
            if character.isNumber {
                result.append(character)
            } else if allowDecimal && character == "." && !hasDecimalSeparator {
                hasDecimalSeparator = true
                if result.isEmpty {
                    result = "0"
                }
                result.append(character)
            }
        }

        return result
    }
}
