import Foundation

/// Common string sanitisation helpers used across invoice flows.
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
                result.append(character)
            }
        }

        return result
    }
}
