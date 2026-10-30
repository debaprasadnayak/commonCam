import Foundation

/// A consumable that raises one of a paid group's limits.
public enum AddOn: String, CaseIterable, Codable, Sendable {
    /// +1 day, +10 GB, +10 people. Amounts are applied by the server.
    case day, storage, people

    public var title: String {
        switch self {
        case .day: "+1 day"
        case .storage: "+10 GB"
        case .people: "+10 people"
        }
    }
}

/// Something a host or co-host buys for an existing group. Apple can't charge an arbitrary amount, so
/// each upgrade (from → to) is its own product priced at the difference between the two tiers.
public enum GroupPurchase: Hashable, Sendable {
    /// `from` is the group's current tier ("taster" or a `PaidTier` raw value).
    case upgrade(from: String, to: PaidTier)
    case addOn(AddOn)

    static let tierOrder = ["taster"] + PaidTier.allCases.map(\.rawValue)

    public var productID: String {
        switch self {
        case .upgrade(let from, let to): "app.commoncam.upgrade.\(from).\(to.rawValue)"
        case .addOn(let addOn): "app.commoncam.addon.\(addOn.rawValue)"
        }
    }

    public init?(productID: String) {
        guard let purchase = Self.all.first(where: { $0.productID == productID }) else { return nil }
        self = purchase
    }

    /// Upgrades to every larger tier, then add-ons (paid groups only).
    public static func available(for group: EventGroup) -> [GroupPurchase] {
        guard let index = tierOrder.firstIndex(of: group.tier) else { return [] }
        let upgrades = PaidTier.allCases.filter { tierOrder.firstIndex(of: $0.rawValue)! > index }
            .map { GroupPurchase.upgrade(from: group.tier, to: $0) }
        let addOns = group.tier == "taster" ? [] : AddOn.allCases.map(GroupPurchase.addOn)
        return upgrades + addOns
    }

    public static var allProductIDs: [String] { all.map(\.productID) }

    private static var all: [GroupPurchase] {
        tierOrder.flatMap { tier in
            available(for: EventGroup(id: "", tier: tier, state: "", peopleCap: 0, storageCapBytes: 0, startsAt: .now, endsAt: .now))
                .filter { if case .upgrade = $0 { true } else { false } }
        } + AddOn.allCases.map(GroupPurchase.addOn)
    }
}

extension APIClient {
    /// Applies an upgrade or add-on bought for `groupID` (host or co-host); returns the group with its new limits.
    /// `signedTransaction` is StoreKit's `jwsRepresentation`; it must carry the group id as `appAccountToken`.
    public func applyPurchase(signedTransaction: String, to groupID: String) async throws -> EventGroup {
        let body = try JSONEncoder().encode(["signedTransaction": signedTransaction])
        return try await send("POST", "groups/\(groupID)/purchases", body: body)
    }
}
