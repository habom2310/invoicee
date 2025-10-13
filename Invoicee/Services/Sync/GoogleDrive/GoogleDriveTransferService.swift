import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
import Security

/// Drive-specific implementation of `CloudStorageTransferService`.
final class GoogleDriveTransferService: NSObject, CloudStorageTransferService {
    enum Constants {
        static let defaultFolderName = "Invoicee"
        static let clientID = "939841720301-9r62ts1ssiqje7tv1ah15rg6do5geloh.apps.googleusercontent.com"
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
    }

    private let credentialStore = GoogleDriveCredentialStore()
    private var token: OAuthToken? = nil
    private(set) var userProfile: GoogleUserProfile?
    var lastErrorDescription: String?
    private var folderCache: [String: String] = [:]

    var currentUserID: String? {
        userProfile?.id
    }

    override init() {
        super.init()
        restorePersistedCredentials()
    }

    private func restorePersistedCredentials() {
        guard let credentials = credentialStore.loadCredentials() else { return }
        token = credentials.token
        userProfile = credentials.profile
    }

    func currentAuthorizationState() -> GoogleDriveAuthorizationState {
        (token != nil && userProfile != nil) ? .linked : .signedOut
    }

    func authorize() async throws {
        do {
            let authURL = try authorizationRequestURL()
#if canImport(AuthenticationServices)
            let callbackURL = try await performAuthorizationSession(url: authURL)
            try await completeAuthorization(callbackURL: callbackURL)
            folderCache.removeAll()
#else
            let error = AuthorizationError.platformUnsupported
            lastErrorDescription = error.localizedDescription
            throw error
#endif
        } catch {
            if lastErrorDescription == nil {
                lastErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    func disconnect() {
        token = nil
        userProfile = nil
        lastErrorDescription = nil
        folderCache.removeAll()
        credentialStore.deleteCredentials()
    }

    func ensureFolder(named name: String) async throws {
        guard token != nil else {
            let error = AuthorizationError.notAuthorized
            lastErrorDescription = error.localizedDescription
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
        guard token != nil else { throw AuthorizationError.notAuthorized }
        let folderID = try await ensureFolderHierarchy(for: metadata)
        let fileID = try await findFile(named: metadata.fileName, inParent: folderID)
        if let existingFileID = fileID {
            try await deleteFile(withID: existingFileID)
        }
        try await uploadFile(fileURL: fileURL, fileName: metadata.fileName, mimeType: metadata.mimeType, parentID: folderID)
    }

    func uploadExport(fileURL: URL, fileName: String) async throws {
        guard token != nil else { throw AuthorizationError.notAuthorized }
        let rootFolderID = try await ensureRootFolderExists()
        try await uploadFile(fileURL: fileURL, fileName: fileName, mimeType: "text/csv", parentID: rootFolderID)
    }

    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data {
        guard token != nil else { throw AuthorizationError.notAuthorized }
        let folderID = try await ensureFolderHierarchy(for: DriveUploadMetadata(invoiceDate: invoiceDate,
                                                                                supplier: "",
                                                                                baseFolderName: Constants.defaultFolderName,
                                                                                fileExtension: (fileName as NSString).pathExtension,
                                                                                increment: 0))
        guard let fileID = try await findFile(named: fileName, inParent: folderID) else {
            throw DriveServiceError.apiError(code: 404, message: "Invoice image not found.")
        }
        return try await downloadFileData(withID: fileID)
    }

    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws {
        guard token != nil else { throw AuthorizationError.notAuthorized }
        let folderID = try await ensureFolderHierarchy(for: DriveUploadMetadata(invoiceDate: invoiceDate,
                                                                                supplier: "",
                                                                                baseFolderName: Constants.defaultFolderName,
                                                                                fileExtension: (fileName as NSString).pathExtension,
                                                                                increment: 0))
        guard let fileID = try await findFile(named: fileName, inParent: folderID) else { return }
        try await deleteFile(withID: fileID)
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
        guard let currentToken = token else { return }
        if !currentToken.isExpired { return }
        guard let refreshToken = currentToken.refreshToken else { return }

        var request = URLRequest(url: Constants.tokenEndpoint)
        request.httpMethod = "POST"
        let bodyParams: [String: String] = [
            "refresh_token": refreshToken,
            "client_id": Constants.clientID,
            "grant_type": "refresh_token"
        ]
        request.httpBody = bodyParams.percentEncoded()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data = try await performRequest(request)
        var refreshed = try JSONDecoder().decode(OAuthToken.self, from: data)
        refreshed.refreshToken = refreshToken
        self.token = refreshed
        credentialStore.save(token: refreshed, profile: userProfile)
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
        let rootFolderID = try await ensureRootFolderExists()
        let yearFolderID = try await ensureFolder(named: metadata.yearFolderName, parentID: rootFolderID)
        let monthFolderID = try await ensureFolder(named: metadata.monthFolderName, parentID: yearFolderID)
        return monthFolderID
    }
}

// MARK: - Network Helpers

private extension GoogleDriveTransferService {
    func performRequest(_ request: URLRequest) async throws -> Data {
        try await refreshTokenIfNeeded()

        var request = request
        if let token {
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveServiceError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            credentialStore.deleteCredentials()
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let driveError = try? JSONDecoder().decode(DriveAPIErrorResponse.self, from: data) {
                throw DriveServiceError.apiError(code: driveError.error.code, message: driveError.error.message)
            }
            throw DriveServiceError.httpError(statusCode: httpResponse.statusCode)
        }

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

        let data = try await performRequest(request)
        let driveFile = try JSONDecoder().decode(DriveFileResponse.self, from: data)
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
        return response.files?.first?.id
    }

    func deleteFile(withID fileID: String) async throws {
        guard let token else { throw AuthorizationError.notAuthorized }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await performRequest(request)
    }

    func downloadFileData(withID fileID: String) async throws -> Data {
        guard let token else { throw AuthorizationError.notAuthorized }
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
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

private struct DriveFileListResponse: Decodable {
    let files: [DriveFileResponse]?
}

private struct DriveFileResponse: Decodable {
    let id: String
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
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(GoogleDriveStoredCredentials.self, from: data) else {
            return nil
        }
        return credentials
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
