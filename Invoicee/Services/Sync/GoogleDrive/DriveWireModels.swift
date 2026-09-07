import Foundation

// MARK: - Errors

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

// MARK: - Request payloads

struct DriveCreateFolderPayload: Encodable {
    let name: String
    let mimeType = GoogleDriveTransferService.Constants.folderMimeType
    let parents: [String]
}

struct DriveFileMetadata: Encodable {
    let name: String
    let parents: [String]
}

struct DriveFileUpdatePayload: Encodable {
    let name: String?
    let addParents: String?
    let removeParents: String?
}

// MARK: - Responses

struct DriveFileListResponse: Decodable {
    let files: [DriveFileResponse]?
}

struct DriveFileResponse: Decodable {
    let id: String
}

struct DriveAPIErrorResponse: Decodable {
    struct DriveErrorDetail: Decodable {
        let code: Int
        let message: String
    }

    let error: DriveErrorDetail
}

/// One HTTP round trip's outcome, kept together so the 401 retry can inspect a response
/// before deciding whether to turn it into an error.
struct DriveResponse {
    let data: Data
    let statusCode: Int
    /// The request that produced it, for logging.
    let description: String
}

// MARK: - Path parsing

/// Splits a recorded upload path — `<base>/<yyyy>/<MM>/<fileName>` — back into its parts.
struct DrivePathComponents {
    let baseFolderName: String
    let yearFolderName: String
    let monthFolderName: String
    let fileName: String

    init?(path: String) {
        let components = path.split(separator: "/").map(String.init)
        // Exactly four: the previous `>= 4` accepted longer paths but still read the base,
        // year, and month from the first three components, so a nested path resolved to
        // the wrong folder while claiming success.
        guard components.count == 4 else { return nil }
        baseFolderName = components[0]
        yearFolderName = components[1]
        monthFolderName = components[2]
        fileName = components[3]
    }
}

// MARK: - Encoding helpers

extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

extension Dictionary where Key == String, Value == String {
    /// Encodes the pairs as an `application/x-www-form-urlencoded` body.
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
