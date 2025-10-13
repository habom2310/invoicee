import Foundation

/// Represents the link status between Invoicee and Google Drive.
enum GoogleDriveAuthorizationState: Equatable {
    case signedOut
    case authorizing
    case linked
    case failed
}
