import Foundation

/// A host's time-boxed shared album, as returned by the API.
/// Named `EventGroup` to avoid clashing with SwiftUI's `Group`.
public struct EventGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let tier: String
    public let state: String
    public let peopleCap: Int
    public let storageCapBytes: Int64
    public let startsAt: Date
    public let endsAt: Date

    public init(
        id: String, tier: String, state: String, peopleCap: Int, storageCapBytes: Int64, startsAt: Date, endsAt: Date
    ) {
        self.id = id
        self.tier = tier
        self.state = state
        self.peopleCap = peopleCap
        self.storageCapBytes = storageCapBytes
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

public struct APIError: Error, Equatable {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }
}

/// Talks to the commonCam Worker API. Every request carries the device token.
public struct APIClient: Sendable {
    private let baseURL: URL
    private let identity: DeviceIdentity
    private let session: URLSession

    public init(baseURL: URL, identity: DeviceIdentity, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.identity = identity
        self.session = session
    }

    public func createTasterGroup() async throws -> EventGroup {
        try await send("POST", "groups", body: Data(#"{"tier":"taster"}"#.utf8))
    }

    public func myGroups() async throws -> [EventGroup] {
        try await send("GET", "groups")
    }

    /// Activates a paid group; `signedTransaction` is StoreKit's `VerificationResult.jwsRepresentation`.
    public func createPaidGroup(tier: PaidTier, signedTransaction: String) async throws -> EventGroup {
        let body = try JSONEncoder().encode(["tier": tier.rawValue, "signedTransaction": signedTransaction])
        return try await send("POST", "groups", body: body)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(try identity.token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(statusCode: status) }
        return try Self.decoder.decode(T.self, from: data)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        }
        return decoder
    }()
}
