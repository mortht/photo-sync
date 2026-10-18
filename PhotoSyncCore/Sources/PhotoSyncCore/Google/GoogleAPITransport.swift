import Foundation

/// Sends authorized requests to Google APIs with retry/backoff for transient
/// errors and one forced token refresh after a 401. Shared by the Library and
/// Picker clients.
struct GoogleAPITransport: Sendable {
    let httpClient: any HTTPClient
    let accessToken: GooglePhotosLibraryClient.AccessTokenProvider
    let retryPolicy: RetryPolicy

    func send(_ request: URLRequest, uploadingFile fileURL: URL? = nil) async throws -> Data {
        try await perform(request, errorBody: { $0 }) { authorized in
            if let fileURL {
                try await httpClient.upload(for: authorized, fromFile: fileURL)
            } else {
                try await httpClient.data(for: authorized)
            }
        }.value
    }

    /// Downloads the response body to a temporary file the caller must move or delete.
    func download(_ request: URLRequest) async throws -> (file: URL, response: HTTPURLResponse) {
        let result = try await perform(request, errorBody: { file in
            defer { try? FileManager.default.removeItem(at: file) }
            return (try? Data(contentsOf: file)) ?? Data()
        }) { authorized in
            try await httpClient.download(for: authorized)
        }
        return (result.value, result.response)
    }

    private func perform<Body>(
        _ request: URLRequest,
        errorBody: (Body) -> Data,
        attempt call: (URLRequest) async throws -> (Body, HTTPURLResponse)
    ) async throws -> (value: Body, response: HTTPURLResponse) {
        var forceRefresh = false
        var attempt = 1
        while true {
            try Task.checkCancellation()
            var authorized = request
            authorized.setValue("Bearer \(try await accessToken(forceRefresh))", forHTTPHeaderField: "Authorization")

            let body: Body
            let response: HTTPURLResponse
            do {
                (body, response) = try await call(authorized)
            } catch where RetryPolicy.isRetryable(error) && attempt < retryPolicy.maxAttempts {
                try await retryPolicy.sleep(retryPolicy.delay(forAttempt: attempt, retryAfter: nil))
                attempt += 1
                continue
            }

            switch response.statusCode {
            case 200..<300:
                return (body, response)
            case 401 where !forceRefresh:
                // Token revoked or expired early: refresh once and retry.
                // Reading the error body also deletes a downloaded file.
                _ = errorBody(body)
                forceRefresh = true
            case let status where RetryPolicy.isRetryable(status: status) && attempt < retryPolicy.maxAttempts:
                _ = errorBody(body)
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await retryPolicy.sleep(retryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter.map { .seconds($0) }))
                attempt += 1
            default:
                throw GoogleAPIError(statusCode: response.statusCode, body: errorBody(body))
            }
        }
    }
}
