import Foundation

/// `nonisolated` so the OCR pass, which runs off the main actor, can use these.
nonisolated extension NSRegularExpression {
    /// A regex from a literal pattern known at compile time.
    ///
    /// Traps on a malformed pattern, which can only be a programming error: the call
    /// sites all pass string literals. Previously some of them built their regex with
    /// `try?` inside the matching loop, silently matching nothing on a typo and
    /// recompiling the pattern for every line of every scan.
    static func compiled(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid regular expression literal '\(pattern)': \(error)")
        }
    }

    private func fullRange(of string: String) -> NSRange {
        NSRange(location: 0, length: string.utf16.count)
    }

    func matches(_ string: String) -> Bool {
        firstMatch(in: string, options: [], range: fullRange(of: string)) != nil
    }

    /// The text of the first match, or `nil` when the pattern does not match.
    func firstMatchText(in string: String) -> String? {
        guard let match = firstMatch(in: string, options: [], range: fullRange(of: string)),
              let range = Range(match.range, in: string) else { return nil }
        return String(string[range])
    }

    /// The captured groups of the first match, excluding the whole-match group.
    func firstMatchGroups(in string: String) -> [String]? {
        guard let match = firstMatch(in: string, options: [], range: fullRange(of: string)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: string).map { String(string[$0]) }
        }
    }
}
