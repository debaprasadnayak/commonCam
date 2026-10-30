import Foundation

/// Persists the device token. Production uses `KeychainTokenStore`.
public protocol TokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
}

/// The anonymous device identity: a random token minted once and reused forever.
public struct DeviceIdentity: Sendable {
    private let store: TokenStore

    public init(store: TokenStore) {
        self.store = store
    }

    public func token() throws -> String {
        if let existing = try store.load() { return existing }
        let token = Self.mint()
        try store.save(token)
        return token
    }

    private static func mint() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
