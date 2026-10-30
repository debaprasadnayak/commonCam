/// A tier the host buys through In-App Purchase. Limits come from the API, never from here.
public enum PaidTier: String, CaseIterable, Codable, Sendable {
    case pocket, party, festival

    /// Shown selected and marked "most popular" on the purchase screen.
    public static let preselected = PaidTier.party

    public var productID: String { "app.commoncam.tier.\(rawValue)" }

    public init?(productID: String) {
        guard let tier = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = tier
    }
}
