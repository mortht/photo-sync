import AppKit
import Observation
import PhotoSyncCore

@MainActor
@Observable
final class GoogleAccountModel {
    enum State: Equatable {
        /// No OAuth client in Secrets.xcconfig.
        case notConfigured
        case signedOut
        case signingIn
        case signedIn(email: String?)
    }

    private(set) var state: State
    var errorMessage: String?

    private let authorizer: GoogleAuthorizer?
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    var isSignedIn: Bool { if case .signedIn = state { true } else { false } }

    init(bundle: Bundle = .main) {
        if let configuration = Self.configuration(from: bundle) {
            authorizer = GoogleAuthorizer(
                configuration: configuration,
                tokenStore: KeychainTokenStore(service: "com.mortht.PhotoSync.google")
            )
            state = .signedOut
        } else {
            authorizer = nil
            state = .notConfigured
        }
    }

    func start() async {
        guard let authorizer, let account = await authorizer.account else { return }
        state = .signedIn(email: account.email)
    }

    func signIn() {
        guard let authorizer, signInTask == nil else { return }
        state = .signingIn
        signInTask = Task {
            defer { signInTask = nil }
            do {
                let account = try await authorizer.signIn { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                state = .signedIn(email: account.email)
            } catch is CancellationError {
                state = .signedOut
            } catch {
                state = .signedOut
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func signOut() async {
        await authorizer?.signOut()
        state = .signedOut
    }

    /// A Library API client using this account's tokens.
    func libraryClient() -> GooglePhotosLibraryClient? {
        guard let authorizer, isSignedIn else { return nil }
        return GooglePhotosLibraryClient { forceRefresh in
            try await authorizer.accessToken(forceRefresh: forceRefresh)
        }
    }

    /// Call when an API call failed; drops to signed-out if the session expired.
    func noteFailure(_ error: any Error) {
        if (error as? GoogleAuthError) == .signInRequired { state = .signedOut }
    }

    static func configuration(from bundle: Bundle) -> GoogleOAuthConfiguration? {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value.hasPrefix("$(") ? nil : value
        }
        guard let clientID = value("GoogleOAuthClientID"), let secret = value("GoogleOAuthClientSecret") else {
            return nil
        }
        return GoogleOAuthConfiguration(clientID: clientID, clientSecret: secret)
    }
}
