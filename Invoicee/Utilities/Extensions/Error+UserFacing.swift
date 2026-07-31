import Foundation

nonisolated extension Error {
    /// The message to show a user for this error.
    ///
    /// `localizedDescription` on a custom `LocalizedError` yields the generic
    /// "The operation couldn’t be completed" wrapper unless `errorDescription` is
    /// consulted first, so every screen was spelling out the same two-step fallback.
    var userFacingDescription: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }

    /// The message to show, or `nil` when this error does not warrant one.
    ///
    /// A `LocalizedError` with no `errorDescription` is declaring itself unreportable —
    /// the convention used for "the user cancelled the picker". Callers used to test for
    /// those cases by downcasting to each specific error type, which meant every new
    /// cancellable flow needed another downcast added to every call site.
    ///
    /// Note this is deliberately *not* `userFacingDescription`'s optional twin: falling
    /// back to `localizedDescription` here would turn a silent cancellation into
    /// "The operation couldn’t be completed. (PickerError error 0.)".
    var reportableDescription: String? {
        if let localized = self as? LocalizedError {
            return localized.errorDescription
        }
        return localizedDescription
    }
}
