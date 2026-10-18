import Foundation

/// Minimal HTTP abstraction so API clients can be tested without a network.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Uploads the body from a file, which avoids loading large videos into memory.
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
    /// Streams the response body to a temporary file the caller owns.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

extension HTTPClient {
    /// Buffers the body in memory; fine for test doubles.
    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        let file = FileManager.default.temporaryDirectory.appending(path: "PhotoSync-download-\(UUID().uuidString)")
        try data.write(to: file)
        return (file, response)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        return (data, try Self.http(response))
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return (data, try Self.http(response))
    }

    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (location, response) = try await session.download(for: request)
        // Move out of URLSession's temporary location before it can be cleaned up.
        let file = FileManager.default.temporaryDirectory.appending(path: "PhotoSync-download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: file)
        return (file, try Self.http(response))
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }
}

extension URLRequest {
    /// A form-encoded POST, as used by OAuth token endpoints.
    static func formPost(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.formEncoded)=\($1.formEncoded)" }.joined(separator: "&").utf8)
        return request
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
