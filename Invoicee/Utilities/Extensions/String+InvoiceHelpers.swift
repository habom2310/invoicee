import Foundation

/// Common string sanitisation helpers used across invoice flows.
///
/// `nonisolated`: the OCR pass and the Drive upload naming both sanitise strings off the
/// main actor.
nonisolated extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when the string is empty, so a blank field can fall through to a default
    /// with `??` instead of an `isEmpty` branch at every call site.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// Keeps digits, and at most one decimal point when `allowDecimal` is set.
    func filteredNumeric(allowDecimal: Bool) -> String {
        var result = ""
        var hasDecimalSeparator = false

        for character in self {
            if character.isNumber {
                result.append(character)
            } else if allowDecimal, character == ".", !hasDecimalSeparator {
                hasDecimalSeparator = true
                result.append(character)
            }
        }

        return result
    }

    /// Case-insensitive membership test, used wherever categories and suppliers are
    /// de-duplicated by name.
    func matchesIgnoringCase(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}

nonisolated extension Collection where Element == String {
    /// `true` when any element matches `candidate` ignoring case.
    func containsIgnoringCase(_ candidate: String) -> Bool {
        contains { $0.matchesIgnoringCase(candidate) }
    }
}
