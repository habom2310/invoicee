import Foundation

/// Clamps a user- or OCR-supplied GST figure to something an invoice could plausibly
/// carry, so a misread receipt cannot poison the reports.
///
/// GST is capped rather than rejected: the amount typed is usually right in shape and
/// wrong in magnitude (a stray digit from OCR), and silently dropping it would hide
/// GST the user can see on the paper invoice.
nonisolated enum GSTValidator {
    static func sanitizedAmount(for gst: Decimal?, total: Decimal?) -> Decimal? {
        guard let gst else { return nil }
        let normalizedGST = max(gst, .zero)

        guard let total, total > 0 else { return normalizedGST }
        return min(normalizedGST, GSTRate.exclusiveGST(on: total))
    }
}
