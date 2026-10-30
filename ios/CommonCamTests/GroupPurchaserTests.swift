import CommonCamKit
import StoreKit
import XCTest
@testable import CommonCam

@MainActor
final class GroupPurchaserTests: StoreKitTestCase {
    private var applied: [(groupID: String, jws: String)] = []
    private let groupID = "6f1c2a4e-7b1d-4c55-9a0e-2b7f8f3d9a10"

    override func setUp() async throws {
        try await super.setUp()
        applied = []
    }

    private var pocketGroup: EventGroup {
        EventGroup(id: groupID, tier: "pocket", state: "Active", peopleCap: 10, storageCapBytes: 1, startsAt: .now, endsAt: .now)
    }

    private func purchaser(failingWith error: Error? = nil) -> GroupPurchaser {
        GroupPurchaser(apply: { [unowned self] jws, groupID in
            if let error { throw error }
            applied.append((groupID, jws))
            return EventGroup(
                id: groupID, tier: "party", state: "Active", peopleCap: 25, storageCapBytes: 1, startsAt: .now, endsAt: .now
            )
        }, buy: buyInSession)
    }

    func testOffersEachUpgradeAtTheDifferenceAndTheAddOns() async throws {
        let offers = try await purchaser().offers(for: pocketGroup)

        XCTAssertEqual(offers.map(\.purchase), [
            .upgrade(from: "pocket", to: .party), .upgrade(from: "pocket", to: .festival),
            .addOn(.day), .addOn(.storage), .addOn(.people),
        ])
        XCTAssertEqual(offers.first?.product.price, Decimal(string: "5.00"))
    }

    func testAnUpgradeIsBoundToTheGroupAndSentToTheAPI() async throws {
        let upgraded = try await purchaser().purchase(.upgrade(from: "pocket", to: .party), for: pocketGroup)

        XCTAssertEqual(upgraded?.tier, "party")
        let application = try XCTUnwrap(applied.first)
        XCTAssertEqual(application.groupID, groupID)
        let payload = try payload(ofJWS: application.jws)
        XCTAssertEqual(payload["productId"] as? String, "app.commoncam.upgrade.pocket.party")
        XCTAssertEqual((payload["appAccountToken"] as? String)?.lowercased(), groupID)
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    func testAnAddOnTheAPIRejectedIsAppliedLaterToTheSameGroup() async throws {
        _ = try? await purchaser(failingWith: APIError(statusCode: 500)).purchase(.addOn(.people), for: pocketGroup)
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await purchaser().applyUnfinished()

        XCTAssertEqual(groups.map(\.id), [groupID])
        XCTAssertEqual(applied.map(\.groupID), [groupID])
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    func testLeavesUnfinishedTierPurchasesToTheTierPurchaser() async throws {
        _ = try? await TierPurchaser(activate: { _, _ in throw APIError(statusCode: 500) }, buy: buyInSession).purchase(.party)
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await purchaser().applyUnfinished()

        XCTAssertEqual(groups, [])
        XCTAssertTrue(applied.isEmpty)
        let unfinished = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinished, 1)
    }
}
