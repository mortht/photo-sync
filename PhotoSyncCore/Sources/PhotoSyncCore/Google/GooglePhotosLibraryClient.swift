import Foundation

/// An album created by Photo Sync in Google Photos.
public struct GoogleAlbum: Sendable, Equatable, Decodable {
    public var id: String
    public var title: String
    public var productUrl: URL?
}

/// An uploaded file to add with `mediaItems:batchCreate`.
public struct NewMediaItem: Sendable, Equatable {
    public var uploadToken: String
    public var fileName: String
    public var description: String?

    public init(uploadToken: String, fileName: String, description: String? = nil) {
        self.uploadToken = uploadToken
        self.fileName = fileName
        self.description = description
    }
}

/// The outcome for one item of a `mediaItems:batchCreate` call.
public struct NewMediaItemResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case created(mediaItemID: String)
        case failed(message: String)
    }

    public var uploadToken: String
    public var status: Status
}

/// Client for the parts of the Google Photos Library API that remain
/// available since March 2025: uploading and app-created albums.
public struct GooglePhotosLibraryClient: Sendable {
    /// Provides an access token; `true` asks for a forced refresh after a 401.
    public typealias AccessTokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    public static let baseURL = URL(string: "https://photoslibrary.googleapis.com/v1/")!
    /// Upper limit of items per `mediaItems:batchCreate` call.
    public static let maxBatchSize = 50
    /// Upper limit of a media item description.
    public static let maxDescriptionLength = 1000

    private let httpClient: any HTTPClient
    private let accessToken: AccessTokenProvider
    private let retryPolicy: RetryPolicy

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), retryPolicy: RetryPolicy = .default,
                accessToken: @escaping AccessTokenProvider) {
        self.httpClient = httpClient
        self.accessToken = accessToken
        self.retryPolicy = retryPolicy
    }

    public func createAlbum(title: String) async throws -> GoogleAlbum {
        struct Body: Encodable { struct Album: Encodable { var title: String }; var album: Album }
        var request = URLRequest(url: Self.baseURL.appending(path: "albums"))
        request.httpMethod = "POST"
        try request.setJSONBody(Body(album: .init(title: title)))
        return try JSONDecoder().decode(GoogleAlbum.self, from: await send(request))
    }

    /// An album the app created earlier, or `nil` if it no longer exists.
    public func album(id: String) async throws -> GoogleAlbum? {
        let request = URLRequest(url: Self.baseURL.appending(path: "albums").appending(path: id))
        do {
            return try JSONDecoder().decode(GoogleAlbum.self, from: await send(request))
        } catch let error as GoogleAPIError where error.statusCode == 404 || error.statusCode == 400 {
            return nil
        }
    }

    /// Uploads the file's bytes and returns an upload token (valid for one day).
    public func uploadFile(at fileURL: URL, fileName: String, mimeType: String) async throws -> String {
        var request = URLRequest(url: Self.baseURL.appending(path: "uploads"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        request.setValue(Self.headerSafe(fileName), forHTTPHeaderField: "X-Goog-Upload-File-Name")
        request.timeoutInterval = 600
        let data = try await send(request, uploadingFile: fileURL)
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw GoogleAPIError(statusCode: 200, message: "Upload returned no token")
        }
        return token
    }

    /// Creates media items from upload tokens, optionally adding them to an album.
    /// Results come back in request order; individual items can fail.
    public func batchCreate(albumID: String?, items: [NewMediaItem]) async throws -> [NewMediaItemResult] {
        precondition(items.count <= Self.maxBatchSize, "batchCreate accepts at most \(Self.maxBatchSize) items")
        struct Body: Encodable {
            struct Item: Encodable {
                struct Simple: Encodable { var uploadToken: String; var fileName: String }
                var description: String?
                var simpleMediaItem: Simple
            }
            var albumId: String?
            var newMediaItems: [Item]
        }
        struct Response: Decodable {
            struct Result: Decodable {
                struct Status: Decodable { var code: Int?; var message: String? }
                struct MediaItem: Decodable { var id: String }
                var uploadToken: String?
                var status: Status?
                var mediaItem: MediaItem?
            }
            var newMediaItemResults: [Result]?
        }

        var request = URLRequest(url: Self.baseURL.appending(path: "mediaItems:batchCreate"))
        request.httpMethod = "POST"
        try request.setJSONBody(Body(albumId: albumID, newMediaItems: items.map {
            .init(description: $0.description.map { String($0.prefix(Self.maxDescriptionLength)) },
                  simpleMediaItem: .init(uploadToken: $0.uploadToken, fileName: $0.fileName))
        }))
        let response = try JSONDecoder().decode(Response.self, from: await send(request))
        let results = response.newMediaItemResults ?? []
        let byToken = Dictionary(results.compactMap { r in r.uploadToken.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })

        return items.enumerated().map { index, item in
            let result = byToken[item.uploadToken] ?? (index < results.count ? results[index] : nil)
            let status: NewMediaItemResult.Status
            if let result, let id = result.mediaItem?.id, (result.status?.code ?? 0) == 0 {
                status = .created(mediaItemID: id)
            } else {
                status = .failed(message: result?.status?.message ?? "No result returned")
            }
            return NewMediaItemResult(uploadToken: item.uploadToken, status: status)
        }
    }

    // MARK: - Sending

    private func send(_ request: URLRequest, uploadingFile fileURL: URL? = nil) async throws -> Data {
        var forceRefresh = false
        var attempt = 1
        while true {
            try Task.checkCancellation()
            var authorized = request
            authorized.setValue("Bearer \(try await accessToken(forceRefresh))", forHTTPHeaderField: "Authorization")

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = if let fileURL {
                    try await httpClient.upload(for: authorized, fromFile: fileURL)
                } else {
                    try await httpClient.data(for: authorized)
                }
            } catch where RetryPolicy.isRetryable(error) && attempt < retryPolicy.maxAttempts {
                try await retryPolicy.sleep(retryPolicy.delay(forAttempt: attempt, retryAfter: nil))
                attempt += 1
                continue
            }

            switch response.statusCode {
            case 200..<300:
                return data
            case 401 where !forceRefresh:
                // Token revoked or expired early: refresh once and retry.
                forceRefresh = true
            case let status where RetryPolicy.isRetryable(status: status) && attempt < retryPolicy.maxAttempts:
                let retryAfter = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                try await retryPolicy.sleep(retryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter.map { .seconds($0) }))
                attempt += 1
            default:
                throw GoogleAPIError(statusCode: response.statusCode, body: data)
            }
        }
    }

    /// HTTP header values must be ASCII; percent-encode anything else.
    static func headerSafe(_ value: String) -> String {
        value.allSatisfy { $0.isASCII && !$0.isNewline }
            ? value
            : value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "upload"
    }
}

private extension URLRequest {
    mutating func setJSONBody(_ body: some Encodable) throws {
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpBody = try JSONEncoder().encode(body)
    }
}
