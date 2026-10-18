import Foundation
import Network

/// Receives the OAuth redirect on `http://127.0.0.1:<port>/`, as Google
/// recommends for desktop apps. Binds to the loopback interface only.
public final class LoopbackRedirectReceiver: @unchecked Sendable {
    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "PhotoSync.LoopbackRedirectReceiver")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, any Error>?
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var callback: Result<URL, any Error>?
    private let responseHTML: String

    public init(responseHTML: String = LoopbackRedirectReceiver.defaultResponseHTML) {
        self.responseHTML = responseHTML
    }

    public static let defaultResponseHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>Photo Sync</title></head>
        <body style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 4em">
        <h2>You're signed in.</h2><p>You can close this tab and return to Photo Sync.</p></body></html>
        """

    /// Starts listening and returns the redirect URI to register with the request.
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.listener = listener
                self.startContinuation = continuation
                // The handlers retain self until `stop()` cancels the listener.
                listener.stateUpdateHandler = { state in self.listenerStateChanged(state) }
                listener.newConnectionHandler = { connection in self.handle(connection) }
                listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the browser to hit the redirect URI and returns the full URL,
    /// including the `code`/`state` or `error` query items.
    public func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let callback = self.callback {
                        continuation.resume(with: callback)
                    } else {
                        self.callbackContinuation = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finish(.failure(CancellationError()))
        }
    }

    // MARK: - Queue-confined

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                startContinuation?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                startContinuation = nil
            }
        case .failed(let error):
            startContinuation?.resume(throwing: error)
            startContinuation = nil
            finish(.failure(error))
        case .cancelled:
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            guard let url = data.flatMap(Self.requestURL(from:)), url.path == "/" || url.path.isEmpty else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            self.respond(connection, status: "200 OK", body: self.responseHTML)
            self.finish(.success(url))
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard callback == nil else { return }
        callback = result
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Parses the request target of `GET /?code=… HTTP/1.1`.
    static func requestURL(from data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8),
              let requestLine = text.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return URL(string: "http://127.0.0.1\(parts[1])")
    }
}
