import Foundation
import Testing
@testable import CommonCamKit

private let upgradedJSON = """
{"id":"g1","tier":"festival","state":"Active","peopleCap":75,"storageCapBytes":107374182400,"storageUsedBytes":0,"storageLevel":"ok",
 "startsAt":"2026-10-30T08:00:00.000Z","endsAt":"2026-11-09T08:00:00.000Z"}
"""

private func group(tier: String) -> EventGroup {
    EventGroup(id: "g1", tier: tier, state: "Active", peopleCap: 1, storageCapBytes: 1, startsAt: .now, endsAt: .now)
}

@Suite struct GroupPurchaseTests {
    @Test func upgradeProductsAreOnePerTierPairPricedAtTheDifference() {
        #expect(GroupPurchase.upgrade(from: "pocket", to: .party).productID == "app.commoncam.upgrade.pocket.party")
        #expect(GroupPurchase(productID: "app.commoncam.upgrade.taster.festival") == .upgrade(from: "taster", to: .festival))
        #expect(GroupPurchase(productID: "app.commoncam.upgrade.festival.party") == nil)
        #expect(GroupPurchase(productID: "app.commoncam.tier.party") == nil)
    }

    @Test func addOnProductIDs() {
        #expect(AddOn.allCases.map { GroupPurchase.addOn($0).productID } == [
            "app.commoncam.addon.day", "app.commoncam.addon.storage", "app.commoncam.addon.people",
        ])
        #expect(GroupPurchase(productID: "app.commoncam.addon.people") == .addOn(.people))
    }

    @Test func offersEveryLargerTierAndAddOnsOnlyForPaidGroups() {
        #expect(GroupPurchase.available(for: group(tier: "taster")) == [
            .upgrade(from: "taster", to: .pocket), .upgrade(from: "taster", to: .party), .upgrade(from: "taster", to: .festival),
        ])
        #expect(GroupPurchase.available(for: group(tier: "party")) == [
            .upgrade(from: "party", to: .festival), .addOn(.day), .addOn(.storage), .addOn(.people),
        ])
        #expect(GroupPurchase.available(for: group(tier: "festival")) == [.addOn(.day), .addOn(.storage), .addOn(.people)])
    }

    @Test func everyPurchasableProductID() {
        #expect(GroupPurchase.allProductIDs.count == 6 + 3)
    }
}

// Shares the serialized suite, since StubURLProtocol state is static.
extension APIClientTests {
    @Test func appliesAPurchaseToTheGroupAndReturnsItsNewLimits() async throws {
        StubURLProtocol.responseBody = Data(upgradedJSON.utf8)

        let upgraded = try await client.applyPurchase(signedTransaction: "header.payload.signature", to: "g1")

        #expect(upgraded.tier == "festival")
        #expect(upgraded.peopleCap == 75)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/purchases")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["signedTransaction": "header.payload.signature"])
    }
}
