import Foundation
import Security

/// Google OAuth tokens for one signed-in account.
public struct OAuthTokens: Sendable, Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: [String]
    public var email: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scopes: [String], email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.email = email
    }

    /// Treats tokens as expired a minute early so requests don't race the expiry.
    func isExpired(at now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) < 60
    }
}

/// Persists OAuth tokens.
public protocol TokenStore: Sendable {
    func load() throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func delete() throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    public init(_ tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() throws -> OAuthTokens? { lock.withLock { tokens } }
    public func save(_ tokens: OAuthTokens) throws { lock.withLock { self.tokens = tokens } }
    public func delete() throws { lock.withLock { tokens = nil } }
}

/// Stores tokens as a generic password item in the user's keychain.
public struct KeychainTokenStore: TokenStore {
    public var service: String
    public var account: String

    public init(service: String, account: String = "default") {
        self.service = service
        self.account = account
    }

    public struct KeychainError: Error, Equatable, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> OAuthTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Photo Sync Google account"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
