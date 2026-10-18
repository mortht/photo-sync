import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) with the S256 method.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init() {
        self.init(verifier: Self.randomURLSafeString(byteCount: 32))
    }

    init(verifier: String) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .base64URLEncodedString
    }
}
