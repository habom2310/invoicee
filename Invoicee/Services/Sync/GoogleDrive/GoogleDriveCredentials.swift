import Foundation
import Security

// MARK: - OAuth models

/// Google's OAuth token response, plus the issue date so expiry can be judged locally.
///
/// Only ever decoded — never constructed by hand — so there is no memberwise initialiser.
/// `init(from:)` is written out because `createdAt` has to default when the key is absent:
/// Google's response does not carry it, and it is added when the token is persisted.
/// `encode(to:)` is deliberately *not* written out; Swift synthesises it from `CodingKeys`.
struct GoogleOAuthToken: Codable {
    let accessToken: String
    let expiresIn: Int
    var refreshToken: String?
    /// Google's assertion of *who* signed in, as opposed to what the app may do on their
    /// behalf. Firebase verifies this to establish the session Firestore rules trust.
    /// Present only because the `openid` scope is requested.
    var idToken: String?
    let tokenType: String
    let scope: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case scope
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        tokenType = try container.decode(String.self, forKey: .tokenType)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var expirationDate: Date {
        createdAt.addingTimeInterval(TimeInterval(expiresIn))
    }

    var isExpired: Bool { Date() >= expirationDate }
}

/// The subset of Google's `userinfo` response the app displays.
struct GoogleUserProfile: Codable {
    let id: String
    let name: String?
    let givenName: String?
    let familyName: String?
    let picture: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case givenName = "given_name"
        case familyName = "family_name"
        case picture
    }

    /// What to show for the linked account, falling back to the first name.
    var displayName: String? { name ?? givenName }
}

// MARK: - Keychain persistence

/// What gets written to the keychain: the token, and the profile it belongs to.
struct GoogleDriveStoredCredentials: Codable {
    let token: GoogleOAuthToken
    let profile: GoogleUserProfile?
}

/// Reads and writes the Drive credentials as a single keychain item.
struct GoogleDriveCredentialStore {
    private let service = "com.invoicee.googleDrive.auth"
    private let account = "oauthCredentials"

    func save(token: GoogleOAuthToken, profile: GoogleUserProfile?) {
        let credentials = GoogleDriveStoredCredentials(token: token, profile: profile)
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.drive.error("Failed to save Google Drive credentials: OSStatus \(status)")
        }
    }

    func loadCredentials() -> GoogleDriveStoredCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        // Matching all, not one: a bug in an earlier version could leave more than one
        // item under this service/account pair, and the newest is the one to trust.
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }

        let decoder = JSONDecoder()
        let decoded = Self.credentialData(from: item)
            .compactMap { try? decoder.decode(GoogleDriveStoredCredentials.self, from: $0) }

        guard let mostRecent = decoded.max(by: { $0.token.createdAt < $1.token.createdAt }) else {
            return nil
        }

        // Collapse duplicates back down to the one we just chose.
        if decoded.count > 1 {
            save(token: mostRecent.token, profile: mostRecent.profile)
        }
        return mostRecent
    }

    /// `kSecMatchLimitAll` returns either a lone `Data` or an array of items, so both
    /// shapes have to be unwrapped.
    private static func credentialData(from item: CFTypeRef?) -> [Data] {
        if let data = item as? Data { return [data] }
        guard let values = item as? [Any] else { return [] }
        return values.compactMap { value in
            if let data = value as? Data { return data }
            return (value as? [String: Any])?[kSecValueData as String] as? Data
        }
    }

    func deleteCredentials() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            AppLog.drive.error("Failed to delete Google Drive credentials: OSStatus \(status)")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
