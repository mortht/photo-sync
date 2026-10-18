import Foundation

/// OAuth scopes used by Photo Sync.
public enum GoogleScope {
    /// Upload media and create albums.
    public static let photosAppendOnly = "https://www.googleapis.com/auth/photoslibrary.appendonly"
    /// Read albums and media the app created.
    public static let photosReadAppCreated = "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata"
    /// Edit albums and media the app created.
    public static let photosEditAppCreated = "https://www.googleapis.com/auth/photoslibrary.edit.appcreateddata"
    /// Read items the user picks in the Picker.
    public static let pickerReadOnly = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"

    /// Everything the app needs, requested once so later features don't require re-consent.
    public static let all = [
        "openid", "email", photosAppendOnly, photosReadAppCreated, photosEditAppCreated, pickerReadOnly,
    ]
    /// Scopes without which album transfers can't work. Google's consent
    /// screen lets users untick individual scopes.
    public static let required = [photosAppendOnly, photosReadAppCreated]
}

/// The OAuth client registered in Google Cloud ("Desktop app" type).
public struct GoogleOAuthConfiguration: Sendable {
    public var clientID: String
    /// Desktop clients get a secret that Google documents as non-confidential.
    public var clientSecret: String
    public var scopes: [String]

    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    public init(clientID: String, clientSecret: String, scopes: [String] = GoogleScope.all) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }
}

public struct GoogleAccount: Sendable, Equatable {
    public var email: String?
}

public enum GoogleAuthError: Error, Equatable, LocalizedError {
    case signInRequired
    case authorizationDenied(String)
    case stateMismatch
    case missingCode
    case missingScopes([String])
    case tokenRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to your Google account to continue."
        case .authorizationDenied(let reason): "Google sign-in was not completed (\(reason))."
        case .stateMismatch: "The sign-in response did not match the request. Please try again."
        case .missingCode: "Google did not return an authorization code."
        case .missingScopes:
            "Photo Sync needs permission to add photos to your Google Photos library. Sign in again and allow all requested access."
        case .tokenRequestFailed(let message): "Google sign-in failed: \(message)"
        }
    }
}

/// Runs the OAuth authorization-code flow with PKCE and a loopback redirect,
/// stores the tokens, and hands out fresh access tokens.
public actor GoogleAuthorizer {
    private let configuration: GoogleOAuthConfiguration
    private let tokenStore: any TokenStore
    private let httpClient: any HTTPClient
    private let now: @Sendable () -> Date
    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, any Error>?

    public init(
        configuration: GoogleOAuthConfiguration,
        tokenStore: any TokenStore,
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.now = now
        tokens = try? tokenStore.load()
    }

    /// The signed-in account, if tokens are stored.
    public var account: GoogleAccount? {
        tokens.map { GoogleAccount(email: $0.email) }
    }

    /// Signs in through the user's browser. `openURL` opens the Google consent page.
    public func signIn(openURL: @Sendable (URL) async -> Void) async throws -> GoogleAccount {
        let receiver = LoopbackRedirectReceiver()
        defer { receiver.stop() }
        let redirectURI = try await receiver.start().absoluteString
        let pkce = PKCE()
        let state = PKCE.randomURLSafeString(byteCount: 16)

        await openURL(authorizationURL(redirectURI: redirectURI, pkce: pkce, state: state))
        let callback = try await receiver.waitForCallback()
        let code = try Self.authorizationCode(from: callback, expectedState: state)

        let response = try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", pkce.verifier),
        ])
        let newTokens = response.tokens(issuedAt: now(), previous: nil)
        let missing = GoogleScope.required.filter { !newTokens.scopes.contains($0) }
        guard missing.isEmpty else { throw GoogleAuthError.missingScopes(missing) }

        try tokenStore.save(newTokens)
        tokens = newTokens
        return GoogleAccount(email: newTokens.email)
    }

    /// Forgets the tokens and revokes them at Google (best effort).
    public func signOut() async {
        let token = tokens?.refreshToken ?? tokens?.accessToken
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        try? tokenStore.delete()
        if let token {
            _ = try? await httpClient.data(for: .formPost(GoogleOAuthConfiguration.revocationEndpoint, [("token", token)]))
        }
    }

    /// A valid access token, refreshed if it is about to expire or `forceRefresh` is set
    /// (e.g. after a 401).
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw GoogleAuthError.signInRequired }
        if !forceRefresh && !current.isExpired(at: now()) { return current.accessToken }
        return try await refreshedTokens(from: current).accessToken
    }

    private func refreshedTokens(from current: OAuthTokens) async throws -> OAuthTokens {
        // Concurrent callers share one refresh.
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = current.refreshToken else { throw GoogleAuthError.signInRequired }

        let task = Task {
            let response = try await tokenRequest([
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
            ])
            return response.tokens(issuedAt: now(), previous: current)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            try tokenStore.save(refreshed)
            tokens = refreshed
            return refreshed
        } catch GoogleAuthError.tokenRequestFailed(let message) where message.hasPrefix("invalid_grant") {
            // The refresh token was revoked or expired (7 days for apps in testing mode).
            tokens = nil
            try? tokenStore.delete()
            throw GoogleAuthError.signInRequired
        }
    }

    // MARK: - Requests

    func authorizationURL(redirectURI: String, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: GoogleOAuthConfiguration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Offline access plus consent guarantees a refresh token.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw GoogleAuthError.authorizationDenied(error) }
        guard value("state") == expectedState else { throw GoogleAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw GoogleAuthError.missingCode }
        return code
    }

    private func tokenRequest(_ fields: [(String, String)]) async throws -> TokenResponse {
        let request = URLRequest.formPost(
            GoogleOAuthConfiguration.tokenEndpoint,
            fields + [("client_id", configuration.clientID), ("client_secret", configuration.clientSecret)]
        )
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            let message = [error?.error, error?.error_description].compactMap { $0 }.joined(separator: ": ")
            throw GoogleAuthError.tokenRequestFailed(message.isEmpty ? "HTTP \(response.statusCode)" : message)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleAuthError.tokenRequestFailed("Unexpected token response")
        }
    }
}

// MARK: - Token endpoint JSON

private struct TokenResponse: Decodable {
    var access_token: String
    var expires_in: Double
    var refresh_token: String?
    var scope: String?
    var id_token: String?

    func tokens(issuedAt date: Date, previous: OAuthTokens?) -> OAuthTokens {
        OAuthTokens(
            accessToken: access_token,
            // Refresh responses don't repeat the refresh token.
            refreshToken: refresh_token ?? previous?.refreshToken,
            expiresAt: date.addingTimeInterval(expires_in),
            scopes: scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? [],
            email: id_token.flatMap(Self.email(fromIDToken:)) ?? previous?.email
        )
    }

    /// Reads the `email` claim. The token comes straight from Google's token
    /// endpoint over TLS, so its signature doesn't need to be verified here.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        struct Claims: Decodable { var email: String? }
        return (try? JSONDecoder().decode(Claims.self, from: payload))?.email
    }
}

private struct TokenErrorResponse: Decodable {
    var error: String?
    var error_description: String?
}
