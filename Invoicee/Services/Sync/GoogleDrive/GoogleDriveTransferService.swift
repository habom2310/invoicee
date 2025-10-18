import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(os)
import os.log
#endif
import Security

#if canImport(os)
private enum DriveLog {
    static let logger = Logger(subsystem: "ha.Invoicee", category: "GoogleDrive")

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
#else
private enum DriveLog {
    static func debug(_ message: String) {
        print("[GoogleDrive][DEBUG] \(message)")
    }

    static func info(_ message: String) {
        print("[GoogleDrive][INFO] \(message)")
    }

    static func error(_ message: String) {
        print("[GoogleDrive][ERROR] \(message)")
    }
}
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
            "https://www.googleapis.com/auth/drive.file",
            "https://www.googleapis.com/auth/userinfo.profile"
        ]
        static var scopeString: String {
            scopes.joined(separator: " ")
        }
        static let maxRefreshAttempts = 3
    }

    private let credentialStore = GoogleDriveCredentialStore()
    private var token: OAuthToken? = nil
    private(set) var userProfile: GoogleUserProfile?
    var lastErrorDescription: String?
    private var folderCache: [String: String] = [:]
    private var consecutiveRefreshFailures = 0

    var currentUserID: String? {
        userProfile?.id
    }

    var currentAccountName: String? {
        userProfile?.name ?? userProfile?.given_name
    }

    override init() {
        super.init()
        restorePersistedCredentials()
    }

    private func restorePersistedCredentials() {
        guard let credentials = credentialStore.loadCredentials() else { return }
        token = credentials.token
        userProfile = credentials.profile
        DriveLog.debug("Restored cached credentials. Token present: \(token != nil), user id: \(userProfile?.id ?? "nil")")
    }

    func currentAuthorizationState() -> GoogleDriveAuthorizationState {
        (token != nil && userProfile != nil) ? .linked : .signedOut
    }

    func performHealthCheck() async -> GoogleDriveAuthorizationState {
        DriveLog.info("Performing Google Drive health check.")
        guard token != nil else {
            userProfile = nil
            DriveLog.debug("No cached token during health check; reporting signed out.")
            return .signedOut
        }

        do {
            try await refreshTokenIfNeeded()
            guard let token else {
                DriveLog.debug("Token missing after refresh; reporting signed out.")
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
            _ = try await ensureRootFolderExists()
            lastErrorDescription = nil
            DriveLog.info("Health check succeeded for user \(profile.id).")
            return .linked
        } catch {
            let isUnauthorized = self.isUnauthorized(error: error)
            if isUnauthorized {
                resetCredentials()
                lastErrorDescription = "Google Drive link expired. Please relink your account."
                DriveLog.error("Health check detected expired credentials: \(error.localizedDescription)")
                return .signedOut
            } else {
                lastErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DriveLog.error("Health check failed: \(error.localizedDescription)")
                return .failed
            }
        }
    }

    func authorize() async throws {
        do {
            let authURL = try authorizationRequestURL()
#if canImport(AuthenticationServices)
            DriveLog.info("Starting Google Drive authorization flow.")
            let callbackURL = try await performAuthorizationSession(url: authURL)
            try await completeAuthorization(callbackURL: callbackURL)
            folderCache.removeAll()
            DriveLog.info("Google Drive authorization completed.")
#else
            let error = AuthorizationError.platformUnsupported
            lastErrorDescription = error.localizedDescription
            throw error
#endif
        } catch {
            if lastErrorDescription == nil {
                lastErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            DriveLog.error("Google Drive authorization failed: \(error.localizedDescription)")
            throw error
        }
    }

    func disconnect() {
        lastErrorDescription = nil
        resetCredentials()
        DriveLog.info("Disconnected Google Drive and cleared local cache.")
    }

    func relocateFileIfNeeded(from existingPath: String, to metadata: DriveUploadMetadata) async throws {
        guard token != nil else { throw AuthorizationError.notAuthorized }
        guard let parsed = DrivePathComponents(path: existingPath) else { return }

        folderCache.removeValue(forKey: parsed.baseFolderName)
        folderCache.removeValue(forKey: parsed.yearFolderName)
        folderCache.removeValue(forKey: parsed.monthFolderName)

        DriveLog.debug("Relocating Drive file from \(existingPath) to \(metadata.fileName).")
        let baseFolderID = try await ensureFolder(named: parsed.baseFolderName, parentID: "root")
        let oldYearFolderID = try await ensureFolder(named: parsed.yearFolderName, parentID: baseFolderID)
        let oldMonthFolderID = try await ensureFolder(named: parsed.monthFolderName, parentID: oldYearFolderID)

        guard let existingFileID = try await findFile(named: parsed.fileName, inParent: oldMonthFolderID) else {
            DriveLog.debug("Existing Drive file not found at path \(existingPath); skipping relocation.")
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
        DriveLog.debug("Drive file \(existingFileID) relocated. move: \(needsMove), rename: \(needsRename)")
    }

    func ensureFolder(named name: String) async throws {
        guard token != nil else {
            let error = AuthorizationError.notAuthorized
            lastErrorDescription = error.localizedDescription
            DriveLog.error("Attempted to ensure folder '\(name)' without authorization.")
            throw error
        }

        if folderCache[name] != nil { return }

        let rootFolderID = try await ensureRootFolderExists()
        let yearFolderID = try await ensureFolder(named: yearFolderName(for: Date()), parentID: rootFolderID)
        folderCache[yearFolderName(for: Date())] = yearFolderID

        let monthFolderID = try await ensureFolder(named: monthFolderName(for: Date()), parentID: yearFolderID)
        folderCache[monthFolderName(for: Date())] = monthFolderID

        if folderCache[name] == nil {
            folderCache[name] = rootFolderID
        }
    }

    func upload(fileURL: URL, metadata: DriveUploadMetadata) async throws {
        guard token != nil else {
            DriveLog.error("Attempted to upload \(metadata.fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let folderID = try await ensureFolderHierarchy(for: metadata)
        let fileID = try await findFile(named: metadata.fileName, inParent: folderID)
        if let existingFileID = fileID {
            try await deleteFile(withID: existingFileID)
            DriveLog.debug("Deleted existing Drive file before upload: \(metadata.fileName)")
        }
        try await uploadFile(fileURL: fileURL, fileName: metadata.fileName, mimeType: metadata.mimeType, parentID: folderID)
        DriveLog.info("Uploaded invoice image to Drive: \(metadata.fileName)")
    }

    func uploadExport(fileURL: URL, fileName: String) async throws {
        guard token != nil else {
            DriveLog.error("Attempted to upload export \(fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let rootFolderID = try await ensureRootFolderExists()
        try await uploadFile(fileURL: fileURL, fileName: fileName, mimeType: "text/csv", parentID: rootFolderID)
        DriveLog.info("Uploaded export file to Drive: \(fileName)")
    }

    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data {
        guard token != nil else {
            DriveLog.error("Attempted to download \(fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let folderID = try await ensureFolderHierarchy(for: DriveUploadMetadata(invoiceDate: invoiceDate,
                                                                                supplier: "",
                                                                                baseFolderName: Constants.defaultFolderName,
                                                                                fileExtension: (fileName as NSString).pathExtension,
                                                                                increment: 0))
        guard let fileID = try await findFile(named: fileName, inParent: folderID) else {
            DriveLog.error("Requested invoice image \(fileName) not found in Drive.")
            throw DriveServiceError.apiError(code: 404, message: "Invoice image not found.")
        }
        DriveLog.debug("Downloading invoice image \(fileName) from Drive.")
        return try await downloadFileData(withID: fileID)
    }

    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws {
        guard token != nil else {
            DriveLog.error("Attempted to delete \(fileName) without authorization.")
            throw AuthorizationError.notAuthorized
        }
        let folderID = try await ensureFolderHierarchy(for: DriveUploadMetadata(invoiceDate: invoiceDate,
                                                                                supplier: "",
                                                                                baseFolderName: Constants.defaultFolderName,
                                                                                fileExtension: (fileName as NSString).pathExtension,
                                                                                increment: 0))
        guard let fileID = try await findFile(named: fileName, inParent: folderID) else { return }
        try await deleteFile(withID: fileID)
        DriveLog.debug("Deleted invoice image \(fileName) from Drive.")
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

        var errorDescription: String? {
            switch self {
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
        var components = URLComponents(url: Constants.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Constants.clientID),
            URLQueryItem(name: "redirect_uri", value: Constants.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Constants.scopeString),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components?.url else {
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
    }
}

// MARK: - Token & Profile

private extension GoogleDriveTransferService {
    func exchangeCodeForToken(code: String) async throws -> OAuthToken {
        var request = URLRequest(url: Constants.tokenEndpoint)
        request.httpMethod = "POST"
        let bodyParams: [String: String] = [
            "code": code,
            "client_id": Constants.clientID,
            "redirect_uri": Constants.redirectURI,
            "grant_type": "authorization_code"
        ]
        request.httpBody = bodyParams.percentEncoded()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data = try await performRequest(request)
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }

    func fetchUserProfile(token: OAuthToken) async throws -> GoogleUserProfile {
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
        guard let currentToken = token else {
            consecutiveRefreshFailures = 0
            return
        }
        if !currentToken.isExpired {
            consecutiveRefreshFailures = 0
            return
        }
        guard let refreshToken = currentToken.refreshToken else { return }

        DriveLog.info("Refreshing Google Drive access token.")
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
            var refreshed = try JSONDecoder().decode(OAuthToken.self, from: data)
            refreshed.refreshToken = refreshToken
            self.token = refreshed
            credentialStore.save(token: refreshed, profile: userProfile)
            consecutiveRefreshFailures = 0
            DriveLog.info("Google Drive token refreshed successfully.")
        } catch {
            consecutiveRefreshFailures += 1
            DriveLog.error("Token refresh failed (attempt \(consecutiveRefreshFailures)): \(error.localizedDescription)")
            if consecutiveRefreshFailures >= Constants.maxRefreshAttempts {
                DriveLog.error("Exceeded maximum token refresh attempts. Clearing credentials.")
                resetCredentials()
                lastErrorDescription = "Google Drive session expired. Please relink your account."
                throw AuthorizationError.notAuthorized
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            throw error
        }
    }
}

// MARK: - Folder Helpers

private extension GoogleDriveTransferService {
    func ensureRootFolderExists() async throws -> String {
        guard token != nil else { throw AuthorizationError.notAuthorized }

        if let cached = folderCache[Constants.defaultFolderName] {
            return cached
        }

        if let existingFolderID = try await findFolder(named: Constants.defaultFolderName, inParent: "root") {
            folderCache[Constants.defaultFolderName] = existingFolderID
            return existingFolderID
        }

        let folderID = try await createFolder(named: Constants.defaultFolderName, parentID: "root")
        folderCache[Constants.defaultFolderName] = folderID
        return folderID
    }

    func ensureFolder(named name: String, parentID: String) async throws -> String {
        if let cached = folderCache[name] {
            return cached
        }

        if let existingFolderID = try await findFolder(named: name, inParent: parentID) {
            folderCache[name] = existingFolderID
            return existingFolderID
        }

        let folderID = try await createFolder(named: name, parentID: parentID)
        folderCache[name] = folderID
        return folderID
    }

    func ensureFolderHierarchy(for metadata: DriveUploadMetadata) async throws -> String {
        let rootFolderID: String
        if metadata.baseFolderName == Constants.defaultFolderName {
            rootFolderID = try await ensureRootFolderExists()
        } else if let cached = folderCache[metadata.baseFolderName] {
            rootFolderID = cached
        } else {
            let baseID = try await ensureFolder(named: metadata.baseFolderName, parentID: "root")
            folderCache[metadata.baseFolderName] = baseID
            rootFolderID = baseID
        }
        let yearFolderID = try await ensureFolder(named: metadata.yearFolderName, parentID: rootFolderID)
        let monthFolderID = try await ensureFolder(named: metadata.monthFolderName, parentID: yearFolderID)
        return monthFolderID
    }
}

// MARK: - Network Helpers

private extension GoogleDriveTransferService {
    func performRequest(_ request: URLRequest,
                        injectAuthorizationHeader: Bool = true,
                        allowRefresh: Bool = true) async throws -> Data {
        if allowRefresh {
            try await refreshTokenIfNeeded()
        }

        var request = request
        if injectAuthorizationHeader, let token {
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }

        let requestDescription = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<unknown>")"
        DriveLog.debug("Drive request: \(requestDescription)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            DriveLog.error("Drive request returned non-HTTP response.")
            throw DriveServiceError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            resetCredentials()
            DriveLog.error("Drive request unauthorized (401). Cleared credentials. Request: \(requestDescription)")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let driveError = try? JSONDecoder().decode(DriveAPIErrorResponse.self, from: data) {
                DriveLog.error("Drive API error \(driveError.error.code) for \(requestDescription): \(driveError.error.message)")
                throw DriveServiceError.apiError(code: driveError.error.code, message: driveError.error.message)
            }
            DriveLog.error("Drive HTTP error \(httpResponse.statusCode) for \(requestDescription).")
            throw DriveServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        DriveLog.debug("Drive request succeeded with status \(httpResponse.statusCode) for \(requestDescription).")
        return data
    }

    func findFolder(named name: String, inParent parentID: String) async throws -> String? {
        guard let token else { throw AuthorizationError.notAuthorized }

        let queryName = name.replacingOccurrences(of: "'", with: "\'")
        let queryParent = parentID.replacingOccurrences(of: "'", with: "\'")
        let query = "name='\(queryName)' and mimeType='application/vnd.google-apps.folder' and '\(queryParent)' in parents and trashed=false"

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(DriveFileListResponse.self, from: data)
        return response.files?.first?.id
    }

    func createFolder(named name: String, parentID: String) async throws -> String {
        guard let token else { throw AuthorizationError.notAuthorized }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let payload = DriveCreateFolderPayload(name: name, parents: [parentID])
        request.httpBody = try JSONEncoder().encode(payload)

        DriveLog.debug("Creating Drive folder '\(name)' under parent \(parentID).")
        let data = try await performRequest(request)
        let driveFile = try JSONDecoder().decode(DriveFileResponse.self, from: data)
        DriveLog.debug("Created Drive folder '\(name)' with id \(driveFile.id).")
        return driveFile.id
    }

    func findFile(named name: String, inParent parentID: String) async throws -> String? {
        guard let token else { throw AuthorizationError.notAuthorized }

        let queryName = name.replacingOccurrences(of: "'", with: "\'")
        let queryParent = parentID.replacingOccurrences(of: "'", with: "\'")
        let query = "name='\(queryName)' and '\(queryParent)' in parents and trashed=false"

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await performRequest(request)
        let response = try JSONDecoder().decode(DriveFileListResponse.self, from: data)
        if let id = response.files?.first?.id {
            DriveLog.debug("Found Drive file '\(name)' in parent \(parentID) with id \(id).")
        } else {
            DriveLog.debug("Drive file '\(name)' not found in parent \(parentID).")
        }
        return response.files?.first?.id
    }

    func deleteFile(withID fileID: String) async throws {
        guard let token else { throw AuthorizationError.notAuthorized }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await performRequest(request)
        DriveLog.debug("Deleted Drive file with id \(fileID).")
    }

    func downloadFileData(withID fileID: String) async throws -> Data {
        guard let token else { throw AuthorizationError.notAuthorized }
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        DriveLog.debug("Downloading Drive file data for id \(fileID).")
        return try await performRequest(request)
    }

    func yearFolderName(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year], from: date)
        let yearValue = components.year ?? 0
        return String(format: "%04d", yearValue)
    }

    func monthFolderName(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.month], from: date)
        let monthValue = components.month ?? 0
        return String(format: "%02d", monthValue)
    }

    func uploadFile(fileURL: URL, fileName: String, mimeType: String, parentID: String) async throws {
        guard let token else { throw AuthorizationError.notAuthorized }
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

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        _ = try await performRequest(request)
    }

    func updateFile(fileID: String, newName: String, oldParent: String?, newParent: String?) async throws {
        guard let token else { throw AuthorizationError.notAuthorized }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let payload = DriveFileUpdatePayload(name: newName,
                                             addParents: newParent,
                                             removeParents: oldParent)
        request.httpBody = try JSONEncoder().encode(payload)

        DriveLog.debug("Updating Drive file \(fileID). rename=\(newName), addParent=\(newParent ?? "nil"), removeParent=\(oldParent ?? "nil")")
        _ = try await performRequest(request)
    }
}

// MARK: - OAuth Token

extension GoogleDriveTransferService {
    struct OAuthToken: Codable {
        let accessToken: String
        let expiresIn: Int
        var refreshToken: String?
        let tokenType: String
        let scope: String?
        let createdAt: Date

        init(accessToken: String,
             expiresIn: Int,
             refreshToken: String?,
             tokenType: String,
             scope: String?,
             createdAt: Date = Date()) {
            self.accessToken = accessToken
            self.expiresIn = expiresIn
            self.refreshToken = refreshToken
            self.tokenType = tokenType
            self.scope = scope
            self.createdAt = createdAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            expiresIn = try container.decode(Int.self, forKey: .expiresIn)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            tokenType = try container.decode(String.self, forKey: .tokenType)
            scope = try container.decodeIfPresent(String.self, forKey: .scope)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(accessToken, forKey: .accessToken)
            try container.encode(expiresIn, forKey: .expiresIn)
            try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
            try container.encode(tokenType, forKey: .tokenType)
            try container.encodeIfPresent(scope, forKey: .scope)
            try container.encode(createdAt, forKey: .createdAt)
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case scope
            case createdAt
        }

        var expirationDate: Date {
            createdAt.addingTimeInterval(TimeInterval(expiresIn))
        }

        var isExpired: Bool { Date() >= expirationDate }
    }

    struct GoogleUserProfile: Codable {
        let id: String
        let name: String?
        let given_name: String?
        let family_name: String?
        let picture: String?
    }
}

// MARK: - Credential Helpers

private extension GoogleDriveTransferService {
    func resetCredentials() {
        token = nil
        userProfile = nil
        folderCache.removeAll()
        credentialStore.deleteCredentials()
        consecutiveRefreshFailures = 0
        DriveLog.debug("Cleared Drive credentials and cache.")
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

// MARK: - Helpers

private struct DriveCreateFolderPayload: Encodable {
    let name: String
    let mimeType: String = "application/vnd.google-apps.folder"
    let parents: [String]
}

private struct DriveFileMetadata: Encodable {
    let name: String
    let parents: [String]
}

private struct DrivePathComponents {
    let baseFolderName: String
    let yearFolderName: String
    let monthFolderName: String
    let fileName: String

    init?(path: String) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 4 else { return nil }
        baseFolderName = components[0]
        yearFolderName = components[1]
        monthFolderName = components[2]
        fileName = components.last!
    }
}

private struct DriveFileListResponse: Decodable {
    let files: [DriveFileResponse]?
}

private struct DriveFileResponse: Decodable {
    let id: String
}

private struct DriveFileUpdatePayload: Encodable {
    let name: String?
    let addParents: String?
    let removeParents: String?
}

private struct DriveAPIErrorResponse: Decodable {
    struct DriveErrorDetail: Decodable {
        let code: Int
        let message: String
    }

    let error: DriveErrorDetail
}

enum DriveServiceError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Received an invalid response from Google Drive."
        case .httpError(let statusCode):
            return "Google Drive request failed with status code \(statusCode)."
        case .apiError(_, let message):
            return message
        }
    }
}

private struct GoogleDriveStoredCredentials: Codable {
    let token: GoogleDriveTransferService.OAuthToken
    let profile: GoogleDriveTransferService.GoogleUserProfile?
}

private struct GoogleDriveCredentialStore {
    private let service = "com.invoicee.googleDrive.auth"
    private let account = "oauthCredentials"

    func save(token: GoogleDriveTransferService.OAuthToken, profile: GoogleDriveTransferService.GoogleUserProfile?) {
        let credentials = GoogleDriveStoredCredentials(token: token, profile: profile)
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            #if DEBUG
            print("Failed to save Google Drive credentials: \(status)")
            #endif
        }
    }

    func loadCredentials() -> GoogleDriveStoredCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }

        let decoder = JSONDecoder()

        let decoded: [GoogleDriveStoredCredentials]
        if let data = item as? Data {
            if let credentials = try? decoder.decode(GoogleDriveStoredCredentials.self, from: data) {
                decoded = [credentials]
            } else {
                decoded = []
            }
        } else if let values = item as? [Any] {
            let dataArray: [Data] = values.compactMap {
                if let data = $0 as? Data { return data }
                if let dict = $0 as? [String: Any], let data = dict[kSecValueData as String] as? Data { return data }
                return nil
            }
            decoded = dataArray.compactMap { try? decoder.decode(GoogleDriveStoredCredentials.self, from: $0) }
        } else {
            decoded = []
        }

        guard !decoded.isEmpty else { return nil }

        if decoded.count == 1 {
            return decoded.first
        }

        let mostRecent = decoded.max { lhs, rhs in
            lhs.token.createdAt < rhs.token.createdAt
        }

        if let mostRecent {
            save(token: mostRecent.token, profile: mostRecent.profile)
        }

        return mostRecent
    }

    func deleteCredentials() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            #if DEBUG
            print("Failed to delete Google Drive credentials: \(status)")
            #endif
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

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func percentEncoded() -> Data? {
        map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
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
