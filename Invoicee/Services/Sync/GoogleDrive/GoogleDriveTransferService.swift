import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Drive-specific implementation of `CloudStorageTransferService`.
final class GoogleDriveTransferService: NSObject, CloudStorageTransferService {
    enum Constants {
        static let defaultFolderName = "Invoicee"
        static let clientID = "164537557679-oe62eqo9fjfga92s3rl72n5ap30tvb96.apps.googleusercontent.com"
        static let redirectURI = "ha.Invoicee:/oauth2redirect/google"
        static var redirectScheme: String {
            URL(string: redirectURI)?.scheme ?? ""
        }
        static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
        static let scopes: [String] = [
            // `openid` is what makes Google return an `id_token`; Firebase needs one to
            // establish the session Firestore rules are written against.
            "openid",
            "https://www.googleapis.com/auth/drive.file",
            "https://www.googleapis.com/auth/userinfo.profile"
        ]
        static var scopeString: String {
            scopes.joined(separator: " ")
        }
        static let maxRefreshAttempts = 3
        static let folderMimeType = "application/vnd.google-apps.folder"
    }

    private let credentialStore = GoogleDriveCredentialStore()
    private let sessionAuthenticator: FirebaseSessionAuthenticating
    private var token: GoogleOAuthToken?
    private(set) var userProfile: GoogleUserProfile?
    private(set) var lastFailureDescription: String?
    /// Held between building the authorization URL and exchanging the code it returns.
    /// One pair per attempt: reusing a verifier would defeat the point of having one.
    private var pendingPKCE: PKCEChallenge?
    /// Resolved folder IDs keyed by parent + name. The parent must be part of the key:
    /// month folders are named "01"…"12" and would otherwise collide across years.
    private var folderCache: [String: String] = [:]
    private var consecutiveRefreshFailures = 0

    var currentUserID: String? {
        userProfile?.id
    }

    var currentAccountName: String? {
        userProfile?.displayName
    }

    /// Non-nil only once Firebase has verified the account, because `uid` is the half
    /// Firestore rules enforce and this app is in no position to assert it itself.
    var currentSyncIdentity: SyncIdentity? {
        guard let uid = sessionAuthenticator.currentUID,
              let googleAccountID = userProfile?.id,
              // The two sessions are stored separately and can name different accounts;
              // syncing on a mismatched pair would file this account's data under the
              // other one's ownership.
              sessionAuthenticator.signedInGoogleAccountID == googleAccountID else {
            return nil
        }
        return SyncIdentity(uid: uid, googleAccountID: googleAccountID)
    }

    init(sessionAuthenticator: FirebaseSessionAuthenticating = FirebaseSessionAuthenticator()) {
        self.sessionAuthenticator = sessionAuthenticator
        super.init()
        restorePersistedCredentials()
    }

    private func restorePersistedCredentials() {
        guard let credentials = credentialStore.loadCredentials() else { return }
        token = credentials.token
        userProfile = credentials.profile
        AppLog.drive.debug("Restored cached credentials. Token present: \(token != nil), user id: \(userProfile?.id ?? "nil")")
    }

    func currentAuthorizationState() -> GoogleDriveAuthorizationState {
        (token != nil && userProfile != nil) ? .linked : .signedOut
    }

    func performHealthCheck() async -> GoogleDriveAuthorizationState {
        AppLog.drive.info("Performing Google Drive health check.")
        guard token != nil else {
            userProfile = nil
            AppLog.drive.debug("No cached token during health check; reporting signed out.")
            return .signedOut
        }

        do {
            try await refreshTokenIfNeeded()
            guard let token else {
                AppLog.drive.debug("Token missing after refresh; reporting signed out.")
                return .signedOut
            }

            let profile: GoogleUserProfile
            if let cachedProfile = userProfile {
                profile = cachedProfile
            } else {
                profile = try await fetchUserProfile(token: token)
            }
            userProfile = profile
            credentialStore.save(token: token, profile: profile)
            try await ensureFirebaseSession()
            _ = try await ensureRootFolderExists()
            lastFailureDescription = nil
            AppLog.drive.info("Health check succeeded for user \(profile.id).")
            return .linked
        } catch {
            let isUnauthorized = self.isUnauthorized(error: error)
            if isUnauthorized {
                resetCredentials()
                lastFailureDescription = "Google Drive link expired. Please relink your account."
                AppLog.drive.error("Health check detected expired credentials: \(error.localizedDescription)")
                return .signedOut
            } else {
                lastFailureDescription = error.userFacingDescription
                AppLog.drive.error("Health check failed: \(error.localizedDescription)")
                return .failed
            }
        }
    }

    func authorize() async throws {
        do {
            let authURL = try authorizationRequestURL()
#if canImport(AuthenticationServices)
            AppLog.drive.info("Starting Google Drive authorization flow.")
            let callbackURL = try await performAuthorizationSession(url: authURL)
            try await completeAuthorization(callbackURL: callbackURL)
            folderCache.removeAll()
            AppLog.drive.info("Google Drive authorization completed.")
#else
            let error = AuthorizationError.platformUnsupported
            lastFailureDescription = error.localizedDescription
            throw error
#endif
        } catch {
            if lastFailureDescription == nil {
                lastFailureDescription = error.userFacingDescription
            }
            AppLog.drive.error("Google Drive authorization failed: \(error.localizedDescription)")
            throw error
        }
    }

    func disconnect() {
        lastFailureDescription = nil
        resetCredentials()
        AppLog.drive.info("Disconnected Google Drive and cleared local cache.")
    }

    func relocateFileIfNeeded(from existingPath: String, to metadata: DriveUploadMetadata) async throws {
        guard token != nil else { throw AuthorizationError.notAuthorized }
        guard let parsed = DrivePathComponents(path: existingPath) else { return }

        AppLog.drive.debug("Relocating Drive file from \(existingPath) to \(metadata.fileName).")

        // Locate, never `ensure`: the old path is somewhere the file *used* to be. Using
        // `ensureFolder` here created the old year/month folders whenever they were
        // already gone — so renaming an invoice's supplier left a trail of empty
        // `Invoicee/2025/07/`-style folders in the user's Drive.
        guard let oldMonthFolderID = try await findFolderPath([parsed.baseFolderName,
                                                              parsed.yearFolderName,
                                                              parsed.monthFolderName]) else {
            AppLog.drive.debug("Old Drive folder for \(existingPath) no longer exists; skipping relocation.")
            return
        }

        guard let existingFileID = try await findFile(named: parsed.fileName, inParent: oldMonthFolderID) else {
            AppLog.drive.debug("Existing Drive file not found at path \(existingPath); skipping relocation.")
            return
        }

        let newMonthFolderID = try await ensureFolderHierarchy(for: metadata)
        let needsMove = newMonthFolderID != oldMonthFolderID
        let needsRename = parsed.fileName != metadata.fileName

        guard needsMove || needsRename else { return }

        try await updateFile(fileID: existingFileID,
                             newName: metadata.fileName,
                             oldParent: needsMove ? oldMonthFolderID : nil,
                             newParent: needsMove ? newMonthFolderID : nil)
        AppLog.drive.debug("Drive file \(existingFileID) relocated. move: \(needsMove), rename: \(needsRename)")
    }

    /// Creates the app's root folder if needed. Year/month subfolders are created lazily
    /// by the upload path, which knows the invoice date.
    func ensureRootFolder() async throws {
        guard token != nil else {
            let error = AuthorizationError.notAuthorized
            lastFailureDescription = error.localizedDescription
            AppLog.drive.error("Attempted to ensure the Drive root folder without authorization.")
            throw error
        }
        _ = try await ensureRootFolderExists()
    }

    func upload(fileURL: URL, metadata: DriveUploadMetadata) async throws {
        guard token != nil else {
            AppLog.drive.error("Attempted to upload \(metadata.fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let folderID = try await ensureFolderHierarchy(for: metadata)
        let fileID = try await findFile(named: metadata.fileName, inParent: folderID)
        if let existingFileID = fileID {
            try await deleteFile(withID: existingFileID)
            AppLog.drive.debug("Deleted existing Drive file before upload: \(metadata.fileName)")
        }
        try await uploadFile(fileURL: fileURL, fileName: metadata.fileName, mimeType: metadata.mimeType, parentID: folderID)
        AppLog.drive.info("Uploaded invoice image to Drive: \(metadata.fileName)")
    }

    func uploadExport(fileURL: URL, fileName: String) async throws {
        guard token != nil else {
            AppLog.drive.error("Attempted to upload export \(fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let rootFolderID = try await ensureRootFolderExists()
        try await uploadFile(fileURL: fileURL, fileName: fileName, mimeType: "text/csv", parentID: rootFolderID)
        AppLog.drive.info("Uploaded export file to Drive: \(fileName)")
    }

    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data {
        guard token != nil else {
            AppLog.drive.error("Attempted to download \(fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let folderID = try await attachmentFolderID(fileName: fileName, invoiceDate: invoiceDate)
        guard let fileID = try await findFile(named: fileName, inParent: folderID) else {
            AppLog.drive.error("Requested invoice image \(fileName) not found in Drive.")
            throw DriveServiceError.apiError(code: 404, message: "Invoice image not found.")
        }
        AppLog.drive.debug("Downloading invoice image \(fileName) from Drive.")
        return try await downloadFileData(withID: fileID)
    }

    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws {
        guard token != nil else {
            AppLog.drive.error("Attempted to delete \(fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let folderID = try await attachmentFolderID(fileName: fileName, invoiceDate: invoiceDate)
        guard let fileID = try await findFile(named: fileName, inParent: folderID) else { return }
        try await deleteFile(withID: fileID)
        AppLog.drive.debug("Deleted invoice image \(fileName) from Drive.")
    }

    /// Resolves the year/month folder an existing attachment lives in.
    private func attachmentFolderID(fileName: String, invoiceDate: Date) async throws -> String {
        let metadata = DriveUploadMetadata(invoiceDate: invoiceDate,
                                          supplier: "",
                                          baseFolderName: Constants.defaultFolderName,
                                          fileExtension: (fileName as NSString).pathExtension,
                                          increment: 0)
        return try await ensureFolderHierarchy(for: metadata)
    }
}

// MARK: - Authorization Flow

private extension GoogleDriveTransferService {
    enum AuthorizationError: LocalizedError {
        case platformUnsupported
        case notAuthorized
        case invalidRedirect
        case tokenExchangeFailed
        case profileFetchFailed
        case sessionVerificationFailed

        var errorDescription: String? {
            switch self {
            case .sessionVerificationFailed:
                return "Please relink your Google account to re-enable secure sync."
            case .platformUnsupported:
                return "Google Drive linking is not supported on this platform."
            case .notAuthorized:
                return "Authorize Google Drive before performing this action."
            case .invalidRedirect:
                return "Failed to parse Google authorization redirect URI."
            case .tokenExchangeFailed:
                return "Unable to exchange the authorization code for an access token."
            case .profileFetchFailed:
                return "Unable to fetch the Google account profile."
            }
        }
    }

    func authorizationRequestURL() throws -> URL {
        let pkce = PKCEChallenge()
        pendingPKCE = pkce

        var components = URLComponents(url: Constants.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Constants.clientID),
            URLQueryItem(name: "redirect_uri", value: Constants.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Constants.scopeString),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCEChallenge.method)
        ]
        guard let url = components?.url else {
            pendingPKCE = nil
            throw AuthorizationError.invalidRedirect
        }
        return url
    }

#if canImport(AuthenticationServices)
    func performAuthorizationSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Constants.redirectScheme) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthorizationError.invalidRedirect)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }
#endif

    /// Makes sure a verified Firebase session backs the Drive credentials.
    ///
    /// Usually a no-op, because Firebase persists its own session across launches. It
    /// earns its place in the two cases where the two sessions diverge: credentials
    /// restored from the keychain onto a fresh install, and a Firebase session revoked
    /// server-side. Both leave the app linked to Drive but unable to read back a single
    /// one of its own documents.
    ///
    /// An account linked before the `openid` scope was requested has a refresh token
    /// that will never yield an ID token, so it has to relink once. That is the whole
    /// migration cost of moving Firestore behind real authentication.
    func ensureFirebaseSession() async throws {
        if sessionAuthenticator.currentUID != nil {
            guard sessionAuthenticator.signedInGoogleAccountID != userProfile?.id else { return }
            // Left over from a previous account: signing in below would otherwise be
            // skipped and every subsequent write attributed to the wrong owner.
            AppLog.drive.info("Firebase session belongs to another account; re-establishing.")
            sessionAuthenticator.signOut()
        }

        // A stored ID token is minutes-fresh at best; the refresh is what produces one
        // Firebase will still accept.
        try await refreshToken(force: true)

        guard let token, let idToken = token.idToken else {
            AppLog.drive.error("No ID token available; account predates the openid scope.")
            resetCredentials()
            lastFailureDescription = AuthorizationError.sessionVerificationFailed.localizedDescription
            throw AuthorizationError.sessionVerificationFailed
        }

        do {
            try await sessionAuthenticator.signIn(idToken: idToken, accessToken: token.accessToken)
        } catch {
            AppLog.drive.error("Firebase sign-in failed: \(error.localizedDescription)")
            lastFailureDescription = AuthorizationError.sessionVerificationFailed.localizedDescription
            throw AuthorizationError.sessionVerificationFailed
        }
    }

    func completeAuthorization(callbackURL: URL) async throws {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthorizationError.invalidRedirect
        }

        let token = try await exchangeCodeForToken(code: code)
        self.token = token
        credentialStore.save(token: token, profile: nil)

        let profile = try await fetchUserProfile(token: token)
        userProfile = profile
        credentialStore.save(token: token, profile: profile)

        // Before the link is reported as successful: an account that reaches Drive but
        // has no Firebase session can upload attachments and then fail every Firestore
        // read, which looks like data loss rather than a failed sign-in.
        try await ensureFirebaseSession()
    }
}

// MARK: - Token & Profile

private extension GoogleDriveTransferService {
    func exchangeCodeForToken(code: String) async throws -> GoogleOAuthToken {
        var request = URLRequest(url: Constants.tokenEndpoint)
        request.httpMethod = "POST"
        var bodyParams: [String: String] = [
            "code": code,
            "client_id": Constants.clientID,
            "redirect_uri": Constants.redirectURI,
            "grant_type": "authorization_code"
        ]
        // Consumed here and nowhere else: a verifier that outlived its exchange could be
        // replayed against a second intercepted code.
        if let verifier = pendingPKCE?.verifier {
            bodyParams["code_verifier"] = verifier
        }
        pendingPKCE = nil
        request.httpBody = bodyParams.percentEncoded()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data = try await performRequest(request)
        return try JSONDecoder().decode(GoogleOAuthToken.self, from: data)
    }

    func fetchUserProfile(token: GoogleOAuthToken) async throws -> GoogleUserProfile {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else {
            throw AuthorizationError.profileFetchFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await performRequest(request)
        return try JSONDecoder().decode(GoogleUserProfile.self, from: data)
    }

    func refreshTokenIfNeeded() async throws {
        try await refreshToken(force: false)
    }

    /// Exchanges the refresh token for a new access token.
    /// - Parameter force: refresh even when the current token has not expired locally,
    ///   used after the server has rejected it.
    func refreshToken(force: Bool) async throws {
        guard let currentToken = token else {
            consecutiveRefreshFailures = 0
            return
        }
        if !force, !currentToken.isExpired {
            consecutiveRefreshFailures = 0
            return
        }
        guard let refreshToken = currentToken.refreshToken else {
            // Expired with no way to refresh: the session is over.
            resetCredentials()
            lastFailureDescription = "Google Drive session expired. Please relink your account."
            throw AuthorizationError.notAuthorized
        }

        AppLog.drive.info("Refreshing Google Drive access token.")
        var request = URLRequest(url: Constants.tokenEndpoint)
        request.httpMethod = "POST"
        let bodyParams: [String: String] = [
            "refresh_token": refreshToken,
            "client_id": Constants.clientID,
            "grant_type": "refresh_token"
        ]
        request.httpBody = bodyParams.percentEncoded()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        do {
            let data = try await performRequest(request,
                                                injectAuthorizationHeader: false,
                                                allowRefresh: false)
            var refreshed = try JSONDecoder().decode(GoogleOAuthToken.self, from: data)
            refreshed.refreshToken = refreshToken
            self.token = refreshed
            credentialStore.save(token: refreshed, profile: userProfile)
            consecutiveRefreshFailures = 0
            AppLog.drive.info("Google Drive token refreshed successfully.")
        } catch {
            consecutiveRefreshFailures += 1
            AppLog.drive.error("Token refresh failed (attempt \(consecutiveRefreshFailures)): \(error.localizedDescription)")
            if consecutiveRefreshFailures >= Constants.maxRefreshAttempts {
                AppLog.drive.error("Exceeded maximum token refresh attempts. Clearing credentials.")
                resetCredentials()
                lastFailureDescription = "Google Drive session expired. Please relink your account."
                throw AuthorizationError.notAuthorized
            }
            throw error
        }
    }
}

// MARK: - Folder Helpers

private extension GoogleDriveTransferService {
    func ensureRootFolderExists() async throws -> String {
        try await ensureFolder(named: Constants.defaultFolderName, parentID: "root")
    }

    func ensureFolder(named name: String, parentID: String) async throws -> String {
        guard token != nil else { throw AuthorizationError.notAuthorized }

        let cacheKey = "\(parentID)/\(name)"
        if let cached = folderCache[cacheKey] {
            return cached
        }

        let folderID: String
        if let existing = try await findFolder(named: name, inParent: parentID) {
            folderID = existing
        } else {
            folderID = try await createFolder(named: name, parentID: parentID)
        }
        folderCache[cacheKey] = folderID
        return folderID
    }

    /// Ensures `base/yyyy/MM` exists and returns the month folder's ID.
    func ensureFolderHierarchy(for metadata: DriveUploadMetadata) async throws -> String {
        var parentID = "root"
        for name in [metadata.baseFolderName, metadata.yearFolderName, metadata.monthFolderName] {
            parentID = try await ensureFolder(named: name, parentID: parentID)
        }
        return parentID
    }

    /// Walks `names` down from the Drive root without creating anything.
    /// - Returns: the last folder's ID, or `nil` as soon as a level is missing.
    func findFolderPath(_ names: [String]) async throws -> String? {
        guard token != nil else { throw AuthorizationError.notAuthorized }

        var parentID = "root"
        for name in names {
            let cacheKey = "\(parentID)/\(name)"
            if let cached = folderCache[cacheKey] {
                parentID = cached
                continue
            }
            guard let found = try await findFolder(named: name, inParent: parentID) else { return nil }
            folderCache[cacheKey] = found
            parentID = found
        }
        return parentID
    }
}

// MARK: - Network Helpers

private extension GoogleDriveTransferService {
    /// Sends a Drive API request, refreshing an expired token first and retrying once if
    /// the server rejects the token anyway.
    ///
    /// The retry matters: `refreshTokenIfNeeded` only acts when the token is *locally*
    /// known to be expired, so a token revoked or rotated server-side still looked valid.
    /// A single 401 then wiped the keychain outright, signing the user out even though the
    /// refresh token was perfectly good — and, mid-sync, stranding the remaining
    /// invoices. Now the refresh token gets its chance first, and credentials are only
    /// cleared when a freshly-minted access token is *also* rejected.
    func performRequest(_ request: URLRequest,
                        injectAuthorizationHeader: Bool = true,
                        allowRefresh: Bool = true) async throws -> Data {
        if allowRefresh {
            try await refreshTokenIfNeeded()
        }

        let response = try await send(request, injectAuthorizationHeader: injectAuthorizationHeader)
        guard response.statusCode == 401, allowRefresh else {
            return try validate(response)
        }

        AppLog.drive.info("Drive request unauthorized (401); forcing a token refresh before giving up.")
        do {
            try await refreshToken(force: true)
        } catch {
            AppLog.drive.error("Forced token refresh after 401 failed: \(error.localizedDescription)")
            return try validate(response)
        }

        let retried = try await send(request, injectAuthorizationHeader: injectAuthorizationHeader)
        if retried.statusCode == 401 {
            resetCredentials()
            AppLog.drive.error("Drive still unauthorized after refresh. Cleared credentials. Request: \(retried.description)")
        }
        return try validate(retried)
    }

    /// One round trip, with the bearer token attached after any refresh so it is never stale.
    func send(_ request: URLRequest, injectAuthorizationHeader: Bool) async throws -> DriveResponse {
        var request = request
        if injectAuthorizationHeader, let token {
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }

        let description = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<unknown>")"
        AppLog.drive.debug("Drive request: \(description)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            AppLog.drive.error("Drive request returned non-HTTP response.")
            throw DriveServiceError.invalidResponse
        }
        return DriveResponse(data: data, statusCode: httpResponse.statusCode, description: description)
    }

    /// Returns the body for a success, or throws the most specific error available.
    func validate(_ response: DriveResponse) throws -> Data {
        guard (200..<300).contains(response.statusCode) else {
            if let driveError = try? JSONDecoder().decode(DriveAPIErrorResponse.self, from: response.data) {
                AppLog.drive.error("Drive API error \(driveError.error.code) for \(response.description): \(driveError.error.message)")
                throw DriveServiceError.apiError(code: driveError.error.code, message: driveError.error.message)
            }
            AppLog.drive.error("Drive HTTP error \(response.statusCode) for \(response.description).")
            throw DriveServiceError.httpError(statusCode: response.statusCode)
        }

        AppLog.drive.debug("Drive request succeeded with status \(response.statusCode) for \(response.description).")
        return response.data
    }

    /// Builds a request for the Drive API. The bearer token is attached by
    /// `performRequest` *after* any refresh, so it is never stale.
    func driveRequest(_ url: URL, method: String = "GET") throws -> URLRequest {
        guard token != nil else { throw AuthorizationError.notAuthorized }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    /// Escapes a value for interpolation into a Drive `q` query string.
    static func escapeQueryValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    func searchURL(query: String) -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        return components.url!
    }

    /// Finds the first non-trashed match for `name` in `parentID`.
    func findEntry(named name: String, inParent parentID: String, mimeType: String? = nil) async throws -> String? {
        var clauses = [
            "name='\(Self.escapeQueryValue(name))'",
            "'\(Self.escapeQueryValue(parentID))' in parents",
            "trashed=false"
        ]
        if let mimeType {
            clauses.insert("mimeType='\(Self.escapeQueryValue(mimeType))'", at: 1)
        }

        let request = try driveRequest(searchURL(query: clauses.joined(separator: " and ")))
        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(DriveFileListResponse.self, from: data)
        return response.files?.first?.id
    }

    func findFolder(named name: String, inParent parentID: String) async throws -> String? {
        try await findEntry(named: name, inParent: parentID, mimeType: Constants.folderMimeType)
    }

    func findFile(named name: String, inParent parentID: String) async throws -> String? {
        let id = try await findEntry(named: name, inParent: parentID)
        AppLog.drive.debug("Drive file '\(name)' in parent \(parentID): \(id ?? "not found").")
        return id
    }

    func createFolder(named name: String, parentID: String) async throws -> String {
        var request = try driveRequest(URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!,
                                      method: "POST")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DriveCreateFolderPayload(name: name, parents: [parentID]))

        AppLog.drive.debug("Creating Drive folder '\(name)' under parent \(parentID).")
        let data = try await performRequest(request)
        let driveFile = try JSONDecoder().decode(DriveFileResponse.self, from: data)
        AppLog.drive.debug("Created Drive folder '\(name)' with id \(driveFile.id).")
        return driveFile.id
    }

    func deleteFile(withID fileID: String) async throws {
        let request = try driveRequest(URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!,
                                      method: "DELETE")
        _ = try await performRequest(request)
        AppLog.drive.debug("Deleted Drive file with id \(fileID).")
    }

    func downloadFileData(withID fileID: String) async throws -> Data {
        let request = try driveRequest(URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!)
        AppLog.drive.debug("Downloading Drive file data for id \(fileID).")
        return try await performRequest(request)
    }

    func uploadFile(fileURL: URL, fileName: String, mimeType: String, parentID: String) async throws {
        let metadata = DriveFileMetadata(name: fileName, parents: [parentID])
        let metadataData = try JSONEncoder().encode(metadata)
        let fileData = try Data(contentsOf: fileURL)

        let boundary = "Boundary-" + UUID().uuidString

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadataData)
        body.appendString("\r\n--\(boundary)\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n--\(boundary)--\r\n")

        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id")
        ]

        var request = try driveRequest(components.url!, method: "POST")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        _ = try await performRequest(request)
    }

    func updateFile(fileID: String, newName: String, oldParent: String?, newParent: String?) async throws {
        var request = try driveRequest(URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!,
                                      method: "PATCH")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let payload = DriveFileUpdatePayload(name: newName,
                                             addParents: newParent,
                                             removeParents: oldParent)
        request.httpBody = try JSONEncoder().encode(payload)

        AppLog.drive.debug("Updating Drive file \(fileID). rename=\(newName), addParent=\(newParent ?? "nil"), removeParent=\(oldParent ?? "nil")")
        _ = try await performRequest(request)
    }
}

// MARK: - Credential Helpers

private extension GoogleDriveTransferService {
    func resetCredentials() {
        token = nil
        userProfile = nil
        pendingPKCE = nil
        folderCache.removeAll()
        credentialStore.deleteCredentials()
        // Leaving the Firebase session behind would keep this device authenticated to
        // another account's documents after the Drive link is gone.
        sessionAuthenticator.signOut()
        consecutiveRefreshFailures = 0
        AppLog.drive.debug("Cleared Drive credentials and cache.")
    }

    func isUnauthorized(error: Error) -> Bool {
        if let authorizationError = error as? AuthorizationError {
            return authorizationError == .notAuthorized
        }

        if let driveError = error as? DriveServiceError {
            switch driveError {
            case .httpError(let statusCode):
                return statusCode == 401
            case .apiError(let code, _):
                return code == 401
            case .invalidResponse:
                return false
            }
        }

        if let urlError = error as? URLError {
            return urlError.code == .userAuthenticationRequired || urlError.code == .userCancelledAuthentication
        }

        return false
    }
}

#if canImport(AuthenticationServices)
extension GoogleDriveTransferService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow ?? UIWindow()
#elseif os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSWindow()
#else
        ASPresentationAnchor()
#endif
    }
}
#endif
