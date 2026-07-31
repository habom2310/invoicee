import CoreGraphics

/// Configures how invoice images are resized prior to upload.
///
/// `nonisolated` because `InvoiceDriveExporter` reads `targetLongestSide` while resizing
/// off the main actor. Without it, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` infers
/// `@MainActor` for these members and the read becomes a cross-isolation access.
nonisolated enum InvoiceImageQuality: String, CaseIterable, Identifiable {
    case medium
    case large
    case actual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .medium: "Medium"
        case .large: "Large"
        case .actual: "Actual Size"
        }
    }

    var description: String {
        switch self {
        case .medium: "Longest side resized to 640 px before upload."
        case .large: "Longest side resized to 1280 px before upload."
        case .actual: "Uploads the original resolution."
        }
    }

    /// The longest side to resize to, or `nil` to upload unchanged.
    var targetLongestSide: CGFloat? {
        switch self {
        case .medium: 640
        case .large: 1280
        case .actual: nil
        }
    }
}
