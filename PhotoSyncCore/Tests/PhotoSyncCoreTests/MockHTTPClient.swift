import Foundation
@testable import PhotoSyncCore

/// Records requests and answers them with a handler.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]

        static func json(_ string: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(string.utf8), headers: ["Content-Type": "application/json"])
        }
    }

    struct Recorded {
        var request: URLRequest
        var uploadedFile: URL?

        var path: String { request.url?.path ?? "" }
        var bodyString: String { request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        var bodyJSON: [String: Any] {
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        var formFields: [String: String] {
            var fields: [String: String] = [:]
            for pair in bodyString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            return fields
        }
    }

    private let lock = NSLock()
    private var _requests: [Recorded] = []
    private let handler: @Sendable (Recorded) throws -> Reply

    init(handler: @escaping @Sendable (Recorded) throws -> Reply) {
        self.handler = handler
    }

    var requests: [Recorded] { lock.withLock { _requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try respond(Recorded(request: request, uploadedFile: nil))
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        try respond(Recorded(request: request, uploadedFile: fileURL))
    }

    /// Answers like `data(for:)` / `upload(for:)`, without recording; for composing fakes.
    func data(for request: URLRequest, uploadedFile: URL?) throws -> Reply {
        try handler(Recorded(request: request, uploadedFile: uploadedFile))
    }

    private func respond(_ recorded: Recorded) throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(recorded) }
        let reply = try handler(recorded)
        let response = HTTPURLResponse(url: recorded.request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

/// A thread-safe counter/box for use inside `@Sendable` handlers.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
    var current: Value { lock.withLock { value } }
}
