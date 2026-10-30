import Foundation

/// The paid extension (#18): the host buys it for an ended group in Grace, which becomes Active again.
public enum GroupExtension {
    public static let productID = "app.commoncam.extension"

    /// The purchase carries its group id as StoreKit's `appAccountToken`, so an unfinished transaction
    /// can still be redeemed for the right group after a crash or failed request.
    public static func appAccountToken(forGroup groupID: String) -> UUID? {
        UUID(uuidString: groupID)
    }

    public static func groupID(fromAppAccountToken token: UUID) -> String {
        token.uuidString.lowercased()
    }
}

extension EventGroup {
    /// Uploads are refused (Grace or Deleted); downloads keep working until the grace period ends.
    public var isReadOnly: Bool { state != "Active" }
}

extension APIClient {
    /// Reopens an ended group; `signedTransaction` is the extension purchase's `jwsRepresentation`.
    public func extendGroup(_ groupID: String, signedTransaction: String) async throws -> EventGroup {
        let body = try JSONEncoder().encode(["signedTransaction": signedTransaction])
        return try await send("POST", "groups/\(groupID)/extend", body: body)
    }
}
