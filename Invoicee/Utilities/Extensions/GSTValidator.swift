import Foundation

/// Validates GST totals against a capped percentage of invoice totals.
enum GSTValidator {
    private static let maximumPercentage = Decimal(string: "0.10")!

    static func sanitizedAmount(for gst: Decimal?, total: Decimal?) -> Decimal? {
        guard let gst else { return nil }
        guard let total, total > 0 else { return gst }

        let maximumAllowed = total * maximumPercentage
        return gst >= maximumAllowed ? nil : gst
    }
}
