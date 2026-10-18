import Foundation
import UniformTypeIdentifiers

/// A Picker session: the user picks items at `pickerUri` in Google Photos.
public struct PickerSession: Sendable, Equatable, Decodable {
    public struct PollingConfig: Sendable, Equatable, Decodable {
        public var pollInterval: String?
        public var timeoutIn: String?
    }

    public var id: String
    /// Returned when the session is created; later polls may leave it out.
    public var pickerUri: URL?
    /// Present while the user hasn't finished picking.
    public var pollingConfig: PollingConfig?
    public var expireTime: Date?
    public var mediaItemsSet: Bool?

    public var isPicked: Bool { mediaItemsSet == true }

    public init(id: String, pickerUri: URL?, pollingConfig: PollingConfig?, expireTime: Date?, mediaItemsSet: Bool?) {
        self.id = id
        self.pickerUri = pickerUri
        self.pollingConfig = pollingConfig
        self.expireTime = expireTime
        self.mediaItemsSet = mediaItemsSet
    }

    private enum CodingKeys: String, CodingKey { case id, pickerUri, pollingConfig, expireTime, mediaItemsSet }

    /// Only `id` is needed and only at creation; polls may return a subset.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        pickerUri = try container.decodeIfPresent(URL.self, forKey: .pickerUri)
        pollingConfig = try container.decodeIfPresent(PollingConfig.self, forKey: .pollingConfig)
        expireTime = try container.decodeIfPresent(Date.self, forKey: .expireTime)
        mediaItemsSet = try container.decodeIfPresent(Bool.self, forKey: .mediaItemsSet)
    }

    /// The picker page, closing itself once the user is done.
    public var autoclosePickerURL: URL? { pickerUri?.appending(path: "autoclose") }
}

/// An item the user picked.
public struct PickedMediaItem: Sendable, Equatable, Decodable, Identifiable {
    public struct MediaFile: Sendable, Equatable, Decodable {
        public struct Metadata: Sendable, Equatable, Decodable {
            public struct Video: Sendable, Equatable, Decodable { public var processingStatus: String? }
            public var videoMetadata: Video?
        }
        public var baseUrl: URL
        public var mimeType: String?
        public var filename: String?
        public var mediaFileMetadata: Metadata?
    }

    /// Persistent across sessions, which makes it usable as a sync key.
    public var id: String
    /// When the photo or video was taken (not uploaded).
    public var createTime: Date?
    /// `PHOTO` or `VIDEO`.
    public var type: String?
    public var mediaFile: MediaFile

    public var kind: MediaKind {
        if let type { return type == "VIDEO" ? .video : .photo }
        return mediaFile.mimeType?.hasPrefix("video/") == true ? .video : .photo
    }

    /// The file name, or one made from the ID when Google sends none.
    public var fileName: String {
        if let name = mediaFile.filename, !name.isEmpty { return name }
        let ext = mediaFile.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (kind == .video ? "mp4" : "jpg")
        return "\(id.prefix(16)).\(ext)"
    }
    /// Videos must finish processing at Google before they can be downloaded.
    public var isReady: Bool {
        kind == .photo || (mediaFile.mediaFileMetadata?.videoMetadata?.processingStatus ?? "READY") == "READY"
    }
}

public enum PickerError: Error, Equatable, LocalizedError {
    case timedOut
    case videoNotReady
    /// A response didn't have the expected shape; the detail names the field.
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut: "The Google Photos picker timed out. Open it again to pick items."
        case .videoNotReady: "Google Photos is still processing this video. Try again later."
        case .unexpectedResponse(let detail): "Unexpected response from the Google Photos Picker: \(detail)."
        }
    }
}

/// Client for the Google Photos Picker API.
public struct GooglePhotosPickerClient: Sendable {
    public static let baseURL = URL(string: "https://photospicker.googleapis.com/v1/")!
    /// The API's per-session limit.
    public static let maxItemsPerSession = 2000
    /// How long `baseUrl`s stay valid; the importer re-lists items before this.
    public static let baseURLLifetime: Duration = .seconds(60 * 60)

    private let transport: GoogleAPITransport

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), retryPolicy: RetryPolicy = .default,
                accessToken: @escaping GooglePhotosLibraryClient.AccessTokenProvider) {
        transport = GoogleAPITransport(httpClient: httpClient, accessToken: accessToken, retryPolicy: retryPolicy)
    }

    public func createSession(maxItemCount: Int = maxItemsPerSession) async throws -> PickerSession {
        var request = URLRequest(url: Self.baseURL.appending(path: "sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"pickingConfig":{"maxItemCount":"\#(maxItemCount)"}}"#.utf8)
        let session = try Self.decode(PickerSession.self, from: await transport.send(request))
        guard !session.id.isEmpty, session.pickerUri != nil else {
            throw PickerError.unexpectedResponse("the new session has no ID or picker link")
        }
        return session
    }

    public func session(id: String) async throws -> PickerSession {
        let request = URLRequest(url: Self.baseURL.appending(path: "sessions").appending(path: id))
        var session = try Self.decode(PickerSession.self, from: await transport.send(request))
        if session.id.isEmpty { session.id = id }
        return session
    }

    public func deleteSession(id: String) async throws {
        var request = URLRequest(url: Self.baseURL.appending(path: "sessions").appending(path: id))
        request.httpMethod = "DELETE"
        _ = try await transport.send(request)
    }

    /// Polls until the user has picked, following the session's suggested
    /// interval and timeout. `sleep` is injectable for tests.
    public func waitForPicking(
        _ session: PickerSession,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> PickerSession {
        var current = session
        var deadline: ContinuousClock.Instant?
        while !current.isPicked {
            let interval = Self.duration(current.pollingConfig?.pollInterval) ?? .seconds(5)
            if let timeout = Self.duration(current.pollingConfig?.timeoutIn) {
                if timeout == .zero { throw PickerError.timedOut }
                deadline = deadline ?? .now + timeout
            }
            if let deadline, ContinuousClock.now >= deadline { throw PickerError.timedOut }
            try await sleep(interval)
            current = try await self.session(id: session.id)
        }
        return current
    }

    /// All items picked in the session.
    public func mediaItems(sessionID: String) async throws -> [PickedMediaItem] {
        struct Page: Decodable {
            var mediaItems: [PickedMediaItem]?
            var nextPageToken: String?
        }
        var items: [PickedMediaItem] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: Self.baseURL.appending(path: "mediaItems"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID),
                                     URLQueryItem(name: "pageSize", value: "100")]
                + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page = try Self.decode(Page.self, from: await transport.send(URLRequest(url: components.url!)))
            items += page.mediaItems ?? []
            pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while pageToken != nil
        return items
    }

    /// Downloads the original bytes into `directory` and returns the file.
    /// Photos come with their Exif data except location, which Google strips.
    /// Videos come transcoded; the extension follows the returned type.
    public func download(_ item: PickedMediaItem, into directory: URL) async throws -> URL {
        guard item.isReady else { throw PickerError.videoNotReady }
        let suffix = item.kind == .video ? "=dv" : "=d"
        let url = URL(string: item.mediaFile.baseUrl.absoluteString + suffix)!
        let (temporary, response) = try await transport.download(URLRequest(url: url))
        let mimeType = response.mimeType ?? item.mediaFile.mimeType ?? "application/octet-stream"
        let destination = directory.appending(path: Self.fileName(item.fileName, mimeType: mimeType))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    // MARK: - Helpers

    /// Keeps the original name unless the bytes are of a different type (e.g. a
    /// `.MOV` delivered as MP4), in which case the extension is replaced.
    static func fileName(_ name: String, mimeType: String) -> String {
        guard let type = UTType(mimeType: mimeType), let newExtension = type.preferredFilenameExtension else {
            return name
        }
        let ext = (name as NSString).pathExtension
        if let current = UTType(filenameExtension: ext), current.conforms(to: type) { return name }
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return "\(stem).\(newExtension)"
    }

    /// Decodes a response, turning decoding errors into a message that names the field.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            func path(_ context: DecodingError.Context, _ key: (any CodingKey)? = nil) -> String {
                let keys = context.codingPath + (key.map { [$0] } ?? [])
                let joined = keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
                return joined.isEmpty ? "the response" : "“\(joined.replacingOccurrences(of: ".[", with: "["))”"
            }
            let detail = switch error {
            case .keyNotFound(let key, let context): "\(path(context, key)) is missing"
            case .valueNotFound(_, let context): "\(path(context)) is empty"
            case .typeMismatch(_, let context): "\(path(context)) has an unexpected type"
            case .dataCorrupted(let context): "\(path(context)) is invalid (\(context.debugDescription))"
            @unknown default: error.localizedDescription
            }
            throw PickerError.unexpectedResponse(detail)
        }
    }

    /// Parses protobuf durations such as `"5s"` or `"3.5s"`.
    static func duration(_ string: String?) -> Duration? {
        guard let string, string.hasSuffix("s"), let seconds = Double(string.dropLast()) else { return nil }
        return .milliseconds(Int64(seconds * 1000))
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            // RFC 3339, with or without fractional seconds.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid timestamp \(string)"))
        }
        return decoder
    }()
}
