import Foundation
import Testing
@testable import PhotoSyncCore

@Suite struct GoogleAuthorizerTests {
    static let configuration = GoogleOAuthConfiguration(clientID: "client-id", clientSecret: "client-secret")
    static let allScopes = GoogleScope.all.joined(separator: " ")

    /// An unsigned JWT carrying an email claim.
    static func idToken(email: String) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString
        let payload = Data(#"{"email":"\#(email)","sub":"1"}"#.utf8).base64URLEncodedString
        return "\(header).\(payload).sig"
    }

    static func tokenReply(access: String = "access-1", refresh: String? = "refresh-1",
                           scope: String = allScopes, email: String? = "me@example.com") -> MockHTTPClient.Reply {
        var fields = [#""access_token":"\#(access)""#, #""expires_in":3599"#, #""scope":"\#(scope)""#,
                      #""token_type":"Bearer""#]
        if let refresh { fields.append(#""refresh_token":"\#(refresh)""#) }
        if let email { fields.append(#""id_token":"\#(idToken(email: email))""#) }
        return .json("{\(fields.joined(separator: ","))}")
    }

    /// Plays the browser: follows the consent URL straight to the redirect URI.
    static func browser(query: @escaping @Sendable (_ state: String) -> String) -> @Sendable (URL) async -> Void {
        { authURL in
            let items = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            let state = items.first { $0.name == "state" }!.value!
            let callback = URL(string: "\(redirect)/?\(query(state))")!
            Task { _ = try? await URLSession.shared.data(from: callback) }
        }
    }

    @Test func pkceMatchesRFC7636Example() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pkceVerifierIsURLSafeAndLongEnough() {
        let verifier = PKCE().verifier
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(PKCE().verifier != verifier)
    }

    @Test func authorizationURLParameters() async {
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: InMemoryTokenStore(),
                                          httpClient: MockHTTPClient { _ in .init() })
        let pkce = PKCE(verifier: "verifier")
        let url = await authorizer.authorizationURL(redirectURI: "http://127.0.0.1:5000", pkce: pkce, state: "xyz")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["client_id"] == "client-id")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5000")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "xyz")
        #expect(items["access_type"] == "offline")
        #expect(items["scope"]?.contains(GoogleScope.photosAppendOnly) == true)
    }

    @Test func callbackParsing() throws {
        let ok = URL(string: "http://127.0.0.1:1/?state=s&code=4/abc&scope=x")!
        #expect(try GoogleAuthorizer.authorizationCode(from: ok, expectedState: "s") == "4/abc")
        #expect(throws: GoogleAuthError.stateMismatch) {
            try GoogleAuthorizer.authorizationCode(from: ok, expectedState: "other")
        }
        let denied = URL(string: "http://127.0.0.1:1/?error=access_denied&state=s")!
        #expect(throws: GoogleAuthError.authorizationDenied("access_denied")) {
            try GoogleAuthorizer.authorizationCode(from: denied, expectedState: "s")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func signInThroughLoopbackRedirect() async throws {
        let http = MockHTTPClient { _ in Self.tokenReply() }
        let store = InMemoryTokenStore()
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http)

        let account = try await authorizer.signIn(openURL: Self.browser { "state=\($0)&code=the-code" })

        #expect(account.email == "me@example.com")
        let tokenRequest = try #require(http.requests.first)
        #expect(tokenRequest.request.url == GoogleOAuthConfiguration.tokenEndpoint)
        let form = tokenRequest.formFields
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "the-code")
        #expect(form["client_secret"] == "client-secret")
        #expect(form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(form["code_verifier"]?.count == 43)

        let saved = try #require(try store.load())
        #expect(saved.accessToken == "access-1")
        #expect(saved.refreshToken == "refresh-1")
        #expect(await authorizer.account == GoogleAccount(email: "me@example.com"))
    }

    @Test(.timeLimit(.minutes(1)))
    func signInDeniedByUser() async {
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: InMemoryTokenStore(),
                                          httpClient: MockHTTPClient { _ in Self.tokenReply() })
        await #expect(throws: GoogleAuthError.authorizationDenied("access_denied")) {
            try await authorizer.signIn(openURL: Self.browser { "error=access_denied&state=\($0)" })
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func signInRejectsMissingPhotosScope() async throws {
        let http = MockHTTPClient { _ in Self.tokenReply(scope: "openid email") }
        let store = InMemoryTokenStore()
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http)
        await #expect(throws: GoogleAuthError.missingScopes(GoogleScope.required)) {
            try await authorizer.signIn(openURL: Self.browser { "state=\($0)&code=c" })
        }
        #expect(try store.load() == nil)
    }

    @Test func validTokenIsReturnedWithoutRefresh() async throws {
        let now = Date()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now + 3600,
                                                   scopes: [], email: nil))
        let http = MockHTTPClient { _ in Self.tokenReply() }
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http,
                                          now: { now })
        #expect(try await authorizer.accessToken() == "a")
        #expect(http.requests.isEmpty)
    }

    @Test func expiredTokenIsRefreshedOnceForConcurrentCallers() async throws {
        let now = Date()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "old", refreshToken: "r", expiresAt: now + 30,
                                                   scopes: ["s"], email: "me@example.com"))
        let http = MockHTTPClient { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return Self.tokenReply(access: "new", refresh: nil, email: nil)
        }
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http,
                                          now: { now })

        async let first = authorizer.accessToken()
        async let second = authorizer.accessToken()
        #expect(try await [first, second] == ["new", "new"])
        #expect(http.requests.count == 1)
        #expect(http.requests[0].formFields["grant_type"] == "refresh_token")

        let saved = try #require(try store.load())
        #expect(saved.refreshToken == "r")
        #expect(saved.email == "me@example.com")
        #expect(saved.expiresAt == now + 3599)
    }

    @Test func revokedRefreshTokenRequiresSignIn() async throws {
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "old", refreshToken: "r", expiresAt: .distantPast,
                                                   scopes: [], email: nil))
        let http = MockHTTPClient { _ in
            .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400)
        }
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http)
        await #expect(throws: GoogleAuthError.signInRequired) { try await authorizer.accessToken() }
        #expect(try store.load() == nil)
        #expect(await authorizer.account == nil)
    }

    @Test func concurrentCallersAllSeeSignInRequiredOnRevokedToken() async throws {
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "old", refreshToken: "r", expiresAt: .distantPast,
                                                   scopes: [], email: nil))
        let http = MockHTTPClient { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .json(#"{"error":"invalid_grant"}"#, status: 400)
        }
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http)
        async let first: Error? = { do { _ = try await authorizer.accessToken(); return nil } catch { return error } }()
        async let second: Error? = { do { _ = try await authorizer.accessToken(); return nil } catch { return error } }()
        let errors = await [first, second]
        #expect(errors.allSatisfy { ($0 as? GoogleAuthError) == .signInRequired })
        #expect(http.requests.count == 1)
    }

    @Test func signOutDuringRefreshIsNotUndone() async throws {
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "old", refreshToken: "r", expiresAt: .distantPast,
                                                   scopes: [], email: nil))
        let http = MockHTTPClient { recorded in
            if recorded.request.url == GoogleOAuthConfiguration.tokenEndpoint { Thread.sleep(forTimeInterval: 0.1) }
            return Self.tokenReply(access: "new")
        }
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http)
        async let refresh = try? authorizer.accessToken()
        try await Task.sleep(for: .milliseconds(30))
        await authorizer.signOut()
        _ = await refresh
        #expect(try store.load() == nil)
        #expect(await authorizer.account == nil)
    }

    @Test func tokensAreLoadedLazily() async throws {
        final class CountingStore: TokenStore, @unchecked Sendable {
            let loads = Locked(0)
            func load() throws -> OAuthTokens? { loads.withValue { $0 += 1 }; return nil }
            func save(_ tokens: OAuthTokens) throws {}
            func delete() throws {}
        }
        let store = CountingStore()
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store,
                                          httpClient: MockHTTPClient { _ in .init() })
        #expect(store.loads.current == 0)
        _ = await authorizer.account
        _ = await authorizer.account
        #expect(store.loads.current == 1)
    }

    @Test func signOutDeletesAndRevokes() async throws {
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture,
                                                   scopes: [], email: nil))
        let http = MockHTTPClient { _ in .init() }
        let authorizer = GoogleAuthorizer(configuration: Self.configuration, tokenStore: store, httpClient: http)
        await authorizer.signOut()
        #expect(try store.load() == nil)
        #expect(http.requests.first?.request.url == GoogleOAuthConfiguration.revocationEndpoint)
        #expect(http.requests.first?.formFields["token"] == "r")
    }

    @Test func loopbackReceiverIgnoresOtherPaths() async throws {
        let receiver = LoopbackRedirectReceiver()
        defer { receiver.stop() }
        let base = try await receiver.start()
        let (_, favicon) = try await URLSession.shared.data(from: base.appending(path: "favicon.ico"))
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)

        let (body, response) = try await URLSession.shared.data(from: URL(string: "\(base)/?code=1&state=2")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("signed in") == true)
        let callback = try await receiver.waitForCallback()
        #expect(callback.query == "code=1&state=2")
    }
}
