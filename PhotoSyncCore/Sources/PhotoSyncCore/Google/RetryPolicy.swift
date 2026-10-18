import Foundation

/// Exponential backoff with jitter for transient Google API failures.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// Injected so tests don't wait.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        maxAttempts: Int = 5,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(32),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.sleep = sleep
    }

    public static let `default` = RetryPolicy()

    /// The delay before retry number `attempt` (1-based), honoring `Retry-After` when given.
    func delay(forAttempt attempt: Int, retryAfter: Duration?) -> Duration {
        if let retryAfter { return min(retryAfter, maxDelay) }
        let exponential = baseDelay * Int(pow(2, Double(attempt - 1)))
        let capped = min(exponential, maxDelay)
        // Full jitter in [50%, 100%] of the capped delay.
        return capped * Double.random(in: 0.5...1)
    }

    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    static func isRetryable(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

/// An error response from a Google API.
public struct GoogleAPIError: Error, Sendable, Equatable, LocalizedError {
    public var statusCode: Int
    public var message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    init(statusCode: Int, body: Data) {
        struct Envelope: Decodable {
            struct Body: Decodable { var message: String? }
            var error: Body?
        }
        let message = (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
            ?? String(data: body, encoding: .utf8).flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        self.init(statusCode: statusCode, message: message)
    }

    public var errorDescription: String? { "Google Photos error \(statusCode): \(message)" }
}
