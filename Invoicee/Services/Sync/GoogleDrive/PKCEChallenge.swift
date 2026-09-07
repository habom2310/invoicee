import Foundation
import CryptoKit

/// A one-shot PKCE verifier/challenge pair (RFC 7636).
///
/// An installed app cannot keep a client secret, so the authorization code is the only
/// thing standing between an attacker and the user's Drive. Any app that manages to
/// claim the `ha.Invoicee` redirect scheme sees that code; without PKCE it can exchange
/// it for real tokens, because the token endpoint has no way to tell the two apps apart.
/// The challenge binds the code to whoever started the flow: only the holder of the
/// original verifier can complete the exchange.
///
/// Google now requires this for new installed-app clients and is retiring the flows that
/// omit it, so this is a correctness requirement as much as a hardening one.
struct PKCEChallenge {
    /// Sent only on the token exchange, proving this app started the flow.
    let verifier: String
    /// Sent on the authorization request, where it is visible but useless on its own.
    let challenge: String

    static let method = "S256"

    init() {
        // 32 bytes lands at 43 base64url characters — the minimum RFC 7636 allows, and
        // what Google's own libraries use.
        var generator = SystemRandomNumberGenerator()
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        verifier = Data(bytes).base64URLEncodedString()
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

private extension Data {
    /// base64url per RFC 4648 §5: the padding and the two characters that would need
    /// percent-encoding in a query string are not allowed in either PKCE field.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
