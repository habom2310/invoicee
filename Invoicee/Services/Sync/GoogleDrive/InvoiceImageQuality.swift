import Foundation
import SwiftUI

/// Configures how invoice images are resized prior to upload.
enum InvoiceImageQuality: String, CaseIterable, Identifiable {
    case medium
    case large
    case actual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .medium: return "Medium"
        case .large: return "Large"
        case .actual: return "Actual Size"
        }
    }

    var description: String {
        switch self {
        case .medium:
            return "Longest side resized to 640 px before upload."
        case .large:
            return "Longest side resized to 1280 px before upload."
        case .actual:
            return "Uploads the original resolution."
        }
    }

    var targetLongestSide: CGFloat? {
        switch self {
        case .medium: return 640
        case .large: return 1280
        case .actual: return nil
        }
    }
}
