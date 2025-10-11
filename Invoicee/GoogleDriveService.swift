import Foundation
import SwiftUI
import Combine
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
import UniformTypeIdentifiers
import Security
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

protocol CloudStorageTransferService {
    func currentAuthorizationState() -> GoogleDriveLinkViewModel.AuthorizationState
    func authorize() async throws
    func disconnect()
    func ensureFolder(named name: String) async throws
    func upload(fileURL: URL, metadata: DriveUploadMetadata) async throws
    func uploadExport(fileURL: URL, fileName: String) async throws
    var currentUserID: String? { get }
    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data
    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws
}

struct DriveUploadMetadata {
    struct ParsedFileName {
        let baseName: String
        let increment: Int
        let imageNumber: Int?
    }

    let invoiceDate: Date
    let supplier: String
    let baseFolderName: String
    private let fileExtensionValue: String
    let increment: Int
    let imageNumber: Int?

    init(invoiceDate: Date,
         supplier: String,
         baseFolderName: String,
         fileExtension: String,
         increment: Int,
         imageNumber: Int? = nil) {
        self.invoiceDate = invoiceDate
        self.supplier = supplier
        self.baseFolderName = baseFolderName
        self.fileExtensionValue = fileExtension.lowercased()
        self.increment = increment
        self.imageNumber = imageNumber
    }

    var yearFolderName: String {
        DriveUploadMetadata.yearFormatter.string(from: invoiceDate)
    }

    var monthFolderName: String {
        DriveUploadMetadata.monthFormatter.string(from: invoiceDate)
    }

    var fileName: String {
        let base = DriveUploadMetadata.baseName(for: invoiceDate, supplier: supplier)
        var name = "\(base)_\(Self.format(value: increment))"
        if let imageNumber {
            name += "_image\(Self.format(value: imageNumber))"
        }
        return "\(name).\(fileExtensionValue)"
    }

    var mimeType: String {
        if let type = UTType(filenameExtension: fileExtensionValue) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }

    var fileExtension: String { fileExtensionValue }

    static func baseName(for invoiceDate: Date, supplier: String) -> String {
        let datePart = fileDateFormatter.string(from: invoiceDate)
        let supplierSlug = slug(from: supplier)
        return "\(datePart)_\(supplierSlug)"
    }

    private static func slug(from supplier: String) -> String {
        let trimmed = supplier.trimmed
        let components = trimmed.split { !$0.isLetter && !$0.isNumber }
        let joined = components.map { String($0) }.joined(separator: "_")
        return joined.isEmpty ? "Unknown_Supplier" : joined
    }

    static func parseFileName(from path: String) -> ParsedFileName? {
        let fileNameWithExtension = path.split(separator: "/").last.map(String.init) ?? path
        let fileName: String
        if let dotIndex = fileNameWithExtension.lastIndex(of: ".") {
            fileName = String(fileNameWithExtension[..<dotIndex])
        } else {
            fileName = fileNameWithExtension
        }
        let components = fileName.split(separator: "_")
        guard components.count >= 4 else { return nil }

        var imageNumber: Int? = nil
        var incrementComponentIndex = components.count - 1
        let lastComponent = components[incrementComponentIndex]

        if let imageValue = Self.parseImageComponent(lastComponent) {
            imageNumber = imageValue
            incrementComponentIndex -= 1
        }

        guard incrementComponentIndex >= 0,
              let incrementValue = Int(components[incrementComponentIndex]) else { return nil }

        let baseComponents = components[..<incrementComponentIndex]
        guard !baseComponents.isEmpty else { return nil }
        let baseName = baseComponents.joined(separator: "_")

        return ParsedFileName(baseName: baseName, increment: incrementValue, imageNumber: imageNumber)
    }

    private static func format(value: Int) -> String {
        String(value)
    }

    private static func parseImageComponent(_ component: Substring) -> Int? {
        guard component.hasPrefix("image") else { return nil }
        let suffix = component.dropFirst("image".count)
        return Int(suffix)
    }

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy_MM_dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

final class GoogleDriveConnector: NSObject, ObservableObject {
    enum SyncError: LocalizedError {
        case missingUserIdentity

        var errorDescription: String? {
            switch self {
            case .missingUserIdentity:
                return "Unable to determine the linked Google account."
            }
        }
    }

    static let shared = GoogleDriveConnector()

    @Published private(set) var state: GoogleDriveLinkViewModel.AuthorizationState = .signedOut
    @Published private(set) var linkedFolderName: String? = nil
    let transferService: CloudStorageTransferService
    private var autoSyncTask: Task<Void, Never>? = nil

    override private init() {
        self.transferService = GoogleDriveTransferService()
        super.init()
        state = transferService.currentAuthorizationState()
        linkedFolderName = transferService.currentUserID != nil ? GoogleDriveTransferService.Constants.defaultFolderName : nil
    }

    func authorizationState() -> GoogleDriveLinkViewModel.AuthorizationState {
        transferService.currentAuthorizationState()
    }

    func linkAccount() async {
        await MainActor.run { self.state = .authorizing }

        do {
            try await transferService.authorize()
            try await transferService.ensureFolder(named: GoogleDriveTransferService.Constants.defaultFolderName)
            await MainActor.run {
                self.state = .linked
                self.linkedFolderName = GoogleDriveTransferService.Constants.defaultFolderName
            }
        } catch {
            await MainActor.run {
                self.state = .failed
            }
        }
    }

    func unlinkAccount() {
        transferService.disconnect()
        state = .signedOut
        linkedFolderName = nil
        autoSyncTask?.cancel()
        autoSyncTask = nil
        Task {
            await InvoiceSyncTracker.shared.reset()
        }
    }

    func syncInvoices(_ invoices: [CapturedInvoice], quality: InvoiceImageQuality) async throws -> Int {
        guard !invoices.isEmpty else { return 0 }

        let tracker = InvoiceSyncTracker.shared
        var incrementLookup = await tracker.highestIncrementLookup()
        var pendingInvoices: [(CapturedInvoice, InvoiceSyncTracker.Record?)] = []
        for invoice in invoices {
            if await tracker.isUpToDate(invoice) { continue }
            let record = await tracker.record(for: invoice.id)
            pendingInvoices.append((invoice, record))
        }

        guard !pendingInvoices.isEmpty else { return 0 }

        guard let userID = transferService.currentUserID else {
            throw SyncError.missingUserIdentity
        }

        var syncedCount = 0
        var driveFolderEnsured = false

        for (invoice, previousRecord) in pendingInvoices {
            var imageFileName: String? = nil
            var imagePathToPersist: String? = nil

            if invoice.imageData != nil {
                let baseName = DriveUploadMetadata.baseName(for: invoice.date, supplier: invoice.supplier)
                let preservedIncrement: Int? = {
                    guard let previousPath = previousRecord?.imagePath,
                          let parsed = DriveUploadMetadata.parseFileName(from: previousPath),
                          parsed.baseName == baseName else {
                        return nil
                    }
                    return parsed.increment
                }()
                let increment: Int = {
                    if let preservedIncrement {
                        return preservedIncrement
                    }
                    let next = (incrementLookup[baseName] ?? 0) + 1
                    return next
                }()
                incrementLookup[baseName] = max(incrementLookup[baseName] ?? 0, increment)

                let imageMetadata = DriveUploadMetadata(
                    invoiceDate: invoice.date,
                    supplier: invoice.supplier,
                    baseFolderName: GoogleDriveTransferService.Constants.defaultFolderName,
                    fileExtension: "jpg",
                    increment: increment
                )

                let expectedPath = drivePath(for: imageMetadata)
                let needsUpload = previousRecord?.imagePath != expectedPath

                if needsUpload {
                    if !driveFolderEnsured {
                        try await transferService.ensureFolder(named: GoogleDriveTransferService.Constants.defaultFolderName)
                        driveFolderEnsured = true
                    }

                    if let imageURL = try InvoiceDriveExporter.exportInvoiceImage(invoice, metadata: imageMetadata, quality: quality) {
                        try await transferService.upload(fileURL: imageURL, metadata: imageMetadata)
                        try? FileManager.default.removeItem(at: imageURL)
                    }
                }

                imageFileName = imageMetadata.fileName
                imagePathToPersist = expectedPath
            } else {
                imagePathToPersist = nil
            }

            try await InvoiceFirestoreUploader.shared.upload(invoice: invoice, imageFileName: imageFileName, userID: userID)
            await tracker.markSynced(invoice: invoice, imagePath: imagePathToPersist)
            syncedCount += 1
        }

        return syncedCount
    }

    func enqueueAutoSync(with invoices: [CapturedInvoice]) {
        guard state == .linked, !invoices.isEmpty else { return }

        autoSyncTask?.cancel()
        autoSyncTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }

            do {
                let qualityRaw = UserDefaults.standard.string(forKey: GoogleDriveLinkViewModel.imageQualityPreferenceKey) ?? InvoiceImageQuality.large.rawValue
                let quality = InvoiceImageQuality(rawValue: qualityRaw) ?? .large
                _ = try await self.syncInvoices(invoices, quality: quality)
            } catch {
                // Silently ignore auto-sync failures to avoid surfacing disruptive alerts
            }
        }
    }

    private func drivePath(for metadata: DriveUploadMetadata) -> String {
        "\(metadata.baseFolderName)/\(metadata.yearFolderName)/\(metadata.monthFolderName)/\(metadata.fileName)"
    }
}

@MainActor
final class GoogleDriveLinkViewModel: ObservableObject {
    enum AuthorizationState: Equatable {
        case signedOut
        case authorizing
        case linked
        case failed
    }

    @Published private(set) var authorizationState: AuthorizationState
    @Published private(set) var linkedFolderName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncStatusMessage: String?
    @Published var imageQuality: InvoiceImageQuality {
        didSet {
            UserDefaults.standard.set(imageQuality.rawValue, forKey: Self.imageQualityPreferenceKey)
        }
    }

    private let connector: GoogleDriveConnector
    private var subscriptions = Set<AnyCancellable>()
    static let imageQualityPreferenceKey = "invoiceImageQualityPreference"

    init(connector: GoogleDriveConnector) {
        self.connector = connector
        authorizationState = connector.authorizationState()
        linkedFolderName = connector.linkedFolderName
        imageQuality = InvoiceImageQuality(rawValue: UserDefaults.standard.string(forKey: Self.imageQualityPreferenceKey) ?? "") ?? .large

        connector.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$authorizationState)

        connector.$linkedFolderName
            .receive(on: DispatchQueue.main)
            .assign(to: &$linkedFolderName)
    }

    func linkAccount() {
        errorMessage = nil
        syncStatusMessage = nil

        Task {
            await connector.linkAccount()
            if connector.state == .failed {
                await MainActor.run {
                    self.errorMessage = connectorStateErrorMessage()
                }
            }
        }
    }

    func unlinkAccount() {
        connector.unlinkAccount()
        syncStatusMessage = nil
    }

    func syncInvoices() {
        errorMessage = nil
        syncStatusMessage = nil

        guard authorizationState == .linked else {
            errorMessage = "Link Google Drive before syncing."
            return
        }

        let invoices = InvoiceArchive.shared.invoices
        guard !invoices.isEmpty else {
            syncStatusMessage = "No invoices available to sync."
            return
        }

        isSyncing = true
        syncStatusMessage = "Preparing invoices for sync…"

        Task {
            do {
                let quality = self.imageQuality
                let syncedCount = try await connector.syncInvoices(invoices, quality: quality)
                self.isSyncing = false
                self.errorMessage = nil
                self.syncStatusMessage = "Synced to Google Drive and Firestore."
            } catch {
                self.isSyncing = false
                self.syncStatusMessage = nil
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
    private func connectorStateErrorMessage() -> String {
        if let error = (connector.transferService as? GoogleDriveTransferService)?.lastErrorDescription {
            return error
        }
        return "Failed to link Google Drive. Please try again."
    }
}

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

    func currentAuthorizationState() -> GoogleDriveLinkViewModel.AuthorizationState {
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

        _ = try await ensureFolder(named: name, inParent: "root")
    }

    func upload(fileURL: URL, metadata: DriveUploadMetadata) async throws {
        guard token != nil else {
            let error = AuthorizationError.notAuthorized
            lastErrorDescription = error.localizedDescription
            throw error
        }

        let baseFolderID = try await ensureFolder(named: metadata.baseFolderName, inParent: "root")
        let yearFolderID = try await ensureFolder(named: metadata.yearFolderName, inParent: baseFolderID)
        let monthFolderID = try await ensureFolder(named: metadata.monthFolderName, inParent: yearFolderID)

        let fileName = metadata.fileName

        if let existingFileID = try await findFile(named: fileName, inParent: monthFolderID) {
            try await deleteFile(withID: existingFileID)
        }

        try await uploadFile(fileURL: fileURL, fileName: fileName, mimeType: metadata.mimeType, parentID: monthFolderID)
    }

    func uploadExport(fileURL: URL, fileName: String) async throws {
        guard token != nil else {
            let error = AuthorizationError.notAuthorized
            lastErrorDescription = error.localizedDescription
            throw error
        }

        let baseFolderID = try await ensureFolder(named: Constants.defaultFolderName, inParent: "root")
        let exportsFolderID = try await ensureFolder(named: "Exports", inParent: baseFolderID)

        if let existingFileID = try await findFile(named: fileName, inParent: exportsFolderID) {
            try await deleteFile(withID: existingFileID)
        }

        try await uploadFile(fileURL: fileURL, fileName: fileName, mimeType: "text/csv", parentID: exportsFolderID)
        lastErrorDescription = nil
    }

    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data {
        guard token != nil else {
            let error = AuthorizationError.notAuthorized
            lastErrorDescription = error.localizedDescription
            throw error
        }

        let baseFolderID = try await ensureFolder(named: Constants.defaultFolderName, inParent: "root")
        let yearFolderID = try await ensureFolder(named: yearFolderName(for: invoiceDate), inParent: baseFolderID)
        let monthFolderID = try await ensureFolder(named: monthFolderName(for: invoiceDate), inParent: yearFolderID)

        guard let fileID = try await findFile(named: fileName, inParent: monthFolderID) else {
            let error = DriveServiceError.apiError(code: 404, message: "Invoice image not found in Google Drive.")
            lastErrorDescription = error.errorDescription
            throw error
        }

        let data = try await downloadFileData(withID: fileID)
        lastErrorDescription = nil
        return data
    }

    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws {
        guard token != nil else {
            let error = AuthorizationError.notAuthorized
            lastErrorDescription = error.localizedDescription
            throw error
        }

        guard let baseFolderID = try await findFolder(named: Constants.defaultFolderName, inParent: "root") else { return }
        guard let yearFolderID = try await findFolder(named: yearFolderName(for: invoiceDate), inParent: baseFolderID) else { return }
        guard let monthFolderID = try await findFolder(named: monthFolderName(for: invoiceDate), inParent: yearFolderID) else { return }

        guard let fileID = try await findFile(named: fileName, inParent: monthFolderID) else {
            return
        }

        try await deleteFile(withID: fileID)
    }

    func authorizationRequestURL() throws -> URL {
        let url = try validatedAuthorizationURL()
        lastErrorDescription = nil
        return url
    }

    func completeAuthorization(callbackURL: URL) async throws {
        do {
            let newToken = try await exchangeCodeForToken(callbackURL: callbackURL)
            let profile = try await fetchUserProfile(accessToken: newToken.accessToken)
            token = newToken
            userProfile = profile
            persistCredentials()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            userProfile = nil
            token = nil
            credentialStore.deleteCredentials()
            throw error
        }
    }

    private func validatedAuthorizationURL() throws -> URL {
        var components = URLComponents(url: Constants.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Constants.clientID),
            URLQueryItem(name: "redirect_uri", value: Constants.redirectURI),
            URLQueryItem(name: "scope", value: Constants.scopeString),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    private func ensureFolder(named name: String, inParent parentID: String) async throws -> String {
        let key = cacheKey(for: name, parentID: parentID)
        if let cached = folderCache[key] {
            return cached
        }

        if let existingID = try await findFolder(named: name, inParent: parentID) {
            folderCache[key] = existingID
            return existingID
        }

        let createdID = try await createFolder(named: name, parentID: parentID)
        folderCache[key] = createdID
        return createdID
    }

    private func cacheKey(for name: String, parentID: String) -> String {
        "\(parentID)|\(name.lowercased())"
    }

    private func findFolder(named name: String, inParent parentID: String) async throws -> String? {
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

    private func createFolder(named name: String, parentID: String) async throws -> String {
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

    private func findFile(named name: String, inParent parentID: String) async throws -> String? {
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

    private func deleteFile(withID fileID: String) async throws {
        guard let token else { throw AuthorizationError.notAuthorized }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await performRequest(request)
    }

    private func downloadFileData(withID fileID: String) async throws -> Data {
        guard let token else { throw AuthorizationError.notAuthorized }
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        return try await performRequest(request)
    }

    private func yearFolderName(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year], from: date)
        let yearValue = components.year ?? 0
        return String(format: "%04d", yearValue)
    }

    private func monthFolderName(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.month], from: date)
        let monthValue = components.month ?? 0
        return String(format: "%02d", monthValue)
    }

    private func uploadFile(fileURL: URL, fileName: String, mimeType: String, parentID: String) async throws {
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

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            lastErrorDescription = DriveServiceError.invalidResponse.errorDescription
            throw DriveServiceError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            if let errorResponse = try? JSONDecoder().decode(DriveAPIErrorResponse.self, from: data) {
                let error = DriveServiceError.apiError(code: errorResponse.error.code, message: errorResponse.error.message)
                lastErrorDescription = error.errorDescription
                throw error
            }
            let error = DriveServiceError.httpError(statusCode: httpResponse.statusCode)
            lastErrorDescription = error.errorDescription
            throw error
        }

        lastErrorDescription = nil
        return data
    }

    private func restorePersistedCredentials() {
        guard let stored = credentialStore.loadCredentials() else { return }
        token = stored.token
        userProfile = stored.profile
    }

    private func persistCredentials() {
        guard let token else {
            credentialStore.deleteCredentials()
            return
        }
        credentialStore.save(token: token, profile: userProfile)
    }

#if canImport(AuthenticationServices)
    private func performAuthorizationSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: URL(string: Constants.redirectURI)?.scheme) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: AuthorizationError.invalidCallbackURL)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.start()
        }
    }

    private func exchangeCodeForToken(callbackURL: URL) async throws -> OAuthToken {
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthorizationError.invalidCallbackURL
        }

        var request = URLRequest(url: Constants.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams: [String: String] = [
            "code": code,
            "client_id": Constants.clientID,
            "redirect_uri": Constants.redirectURI,
            "grant_type": "authorization_code"
        ]
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let apiError = try? JSONDecoder().decode(DriveAPIErrorResponse.self, from: data) {
                throw DriveServiceError.apiError(code: apiError.error.code, message: apiError.error.message)
            }

            throw DriveServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let token_type: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))

        return OAuthToken(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token ?? "",
            expirationDate: expiration
        )
    }

    private func fetchUserProfile(accessToken: String) async throws -> GoogleUserProfile {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            lastErrorDescription = DriveServiceError.invalidResponse.errorDescription
            throw DriveServiceError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let error = DriveServiceError.httpError(statusCode: httpResponse.statusCode)
            lastErrorDescription = error.errorDescription
            throw error
        }

        do {
            let profile = try JSONDecoder().decode(GoogleUserProfile.self, from: data)
            lastErrorDescription = nil
            return profile
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }
#endif
}

// MARK: - Authentication Context

#if canImport(AuthenticationServices)
extension GoogleDriveTransferService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
#elseif os(macOS)
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
#else
        ASPresentationAnchor()
#endif
    }
}
#endif

// MARK: - Supporting Types

extension GoogleDriveTransferService {
    enum AuthorizationError: LocalizedError {
        case platformUnsupported
        case invalidCallbackURL
        case notAuthorized
        case invalidConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .platformUnsupported:
                return "Google Drive linking is not supported on this platform."
            case .invalidCallbackURL:
                return "The authorization response was invalid."
            case .notAuthorized:
                return "Please link Google Drive before performing this action."
            case .invalidConfiguration(let message):
                return message
            }
        }
    }

    struct OAuthToken: Codable {
        let accessToken: String
        let refreshToken: String
        let expirationDate: Date

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

// MARK: - Image Export Helpers

enum InvoiceDriveExporter {
    static func exportInvoiceImage(_ invoice: CapturedInvoice,
                                   metadata: DriveUploadMetadata,
                                   quality: InvoiceImageQuality) throws -> URL? {
        guard let imageData = invoice.imageData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(metadata.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let dataToWrite = resizedImageDataIfNeeded(from: imageData, quality: quality) ?? imageData
        try dataToWrite.write(to: url, options: .atomic)
        return url
    }

    private static func resizedImageDataIfNeeded(from data: Data, quality: InvoiceImageQuality) -> Data? {
        guard let longestSide = quality.targetLongestSide else { return nil }
#if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > longestSide else { return nil }
        let resized = resize(image: image, longestSide: longestSide)
        guard let jpegData = resized.jpegData(compressionQuality: 0.85) else { return nil }
        return jpegData
#elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > longestSide else { return nil }
        guard let resized = resize(image: image, longestSide: longestSide) else { return nil }
        return jpegData(from: resized, compression: 0.85)
#else
        return nil
#endif
    }

#if canImport(UIKit)
    private static func resize(image: UIImage, longestSide: CGFloat) -> UIImage {
        let originalSize = image.size
        let maxSide = max(originalSize.width, originalSize.height)
        guard maxSide > longestSide else { return image }
        let scale = longestSide / maxSide
        let newSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resized ?? image
    }
#elseif canImport(AppKit)
    private static func resize(image: NSImage, longestSide: CGFloat) -> NSImage? {
        let originalSize = image.size
        let maxSide = max(originalSize.width, originalSize.height)
        guard maxSide > longestSide else { return image }
        let scale = longestSide / maxSide
        let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    private static func jpegData(from image: NSImage, compression: CGFloat) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
#endif
}

// MARK: - Sync Tracker

actor InvoiceSyncTracker {
    static let shared = InvoiceSyncTracker()

    struct Record: Codable {
        let lastEdited: Date
        let imagePath: String?
    }

    private let storageKey = "invoiceSyncedRecords"
    private var records: [UUID: Record]

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
            let mapped = stored.compactMap { (key, value) -> (UUID, Record)? in
                guard let uuid = UUID(uuidString: key) else { return nil }
                return (uuid, value)
            }
            records = Dictionary(uniqueKeysWithValues: mapped)
        } else {
            records = [:]
        }
    }

    func record(for id: UUID) -> Record? {
        records[id]
    }

    func isUpToDate(_ invoice: CapturedInvoice) -> Bool {
        guard let record = records[invoice.id] else { return false }
        return record.lastEdited >= invoice.lastEdited
    }

    func markSynced(invoice: CapturedInvoice, imagePath: String?) {
        records[invoice.id] = Record(lastEdited: invoice.lastEdited, imagePath: imagePath)
        persist()
    }

    func removeRecord(for id: UUID) {
        records.removeValue(forKey: id)
        persist()
    }

    func highestIncrementLookup() -> [String: Int] {
        records.values.reduce(into: [:]) { partialResult, record in
            guard let path = record.imagePath,
                  let parsed = DriveUploadMetadata.parseFileName(from: path) else { return }
            let current = partialResult[parsed.baseName] ?? 0
            partialResult[parsed.baseName] = max(current, parsed.increment)
        }
    }

    func reset() {
        records.removeAll()
        persist()
    }

    private func persist() {
        let stringKeyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stringKeyed) {
            UserDefaults.standard.set(data, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }
}
