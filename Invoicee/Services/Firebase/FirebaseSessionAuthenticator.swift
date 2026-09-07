import Foundation
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

/// Establishes the Firebase identity that Firestore rules enforce ownership against.
///
/// Without this the app talks to Firestore as an anonymous caller, so no rule can tell
/// one user's documents from another's — and `GoogleService-Info.plist` ships inside
/// every IPA, so "anonymous caller" means anyone at all. The Google account the Drive
/// flow already authenticates is reused here: Firebase verifies the ID token against
/// Google directly, which is why `uid` can be trusted where a client-supplied account
/// ID cannot.
protocol FirebaseSessionAuthenticating {
    /// The signed-in Firebase user, or `nil` when no session has been established yet.
    var currentUID: String? { get }

    /// The Google account the current Firebase session was established with.
    ///
    /// Firebase outlives the app's own Drive credentials — it restores its session from
    /// its own keychain item — so the two can in principle name different accounts.
    /// Callers compare this against the linked Drive profile before trusting `currentUID`;
    /// pairing a stale uid with a freshly linked account would stamp one user's documents
    /// with another user's ownership, which is the exact failure the rules exist to stop.
    var signedInGoogleAccountID: String? { get }

    /// Exchanges a Google ID token for a Firebase session.
    /// - Returns: the Firebase `uid` that documents should be stamped with.
    @discardableResult
    func signIn(idToken: String, accessToken: String) async throws -> String

    func signOut()
}

/// Raised when a Firebase session is required but could not be established.
struct FirebaseSessionUnavailableError: LocalizedError {
    let errorDescription: String? = "Unable to verify your Google account with Invoicee's sync service."
}

struct FirebaseSessionAuthenticator: FirebaseSessionAuthenticating {
#if canImport(FirebaseAuth)
    var currentUID: String? { Auth.auth().currentUser?.uid }

    var signedInGoogleAccountID: String? {
        Auth.auth().currentUser?.providerData
            .first { $0.providerID == GoogleAuthProviderID }?
            .uid
    }

    @discardableResult
    func signIn(idToken: String, accessToken: String) async throws -> String {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                       accessToken: accessToken)
        let result = try await Auth.auth().signIn(with: credential)
        AppLog.drive.info("Firebase session established.")
        return result.user.uid
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            // Nothing actionable: the local session is discarded either way, and the
            // Drive credentials this accompanies have already been cleared.
            AppLog.drive.error("Firebase sign-out failed: \(error.localizedDescription)")
        }
    }
#else
    var currentUID: String? { nil }

    var signedInGoogleAccountID: String? { nil }

    @discardableResult
    func signIn(idToken: String, accessToken: String) async throws -> String {
        throw FirebaseSessionUnavailableError()
    }

    func signOut() {}
#endif
}
