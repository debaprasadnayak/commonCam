import CommonCamKit
import StoreKit
import XCTest
@testable import CommonCam

@MainActor
final class GroupExtenderTests: StoreKitTestCase {
    private let groupID = "0b6f7c1e-3a5d-4c2e-9f10-5d2b8a7e4c11"
    private var extensions: [(groupID: String, jws: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        extensions = []
    }

    private func extender(failingWith error: Error? = nil) -> GroupExtender {
        GroupExtender(extend: { [unowned self] groupID, jws in
            if let error { throw error }
            extensions.append((groupID, jws))
            return EventGroup(id: groupID, tier: "taster", state: "Active", peopleCap: 4, storageCapBytes: 1, startsAt: .now, endsAt: .now)
        }, buy: buyInSession)
    }

    func testBuyingAnExtensionSendsItsTransactionForThatGroupAndFinishesIt() async throws {
        let group = try await extender().purchase(for: groupID)

        XCTAssertEqual(group?.state, "Active")
        let sent = try XCTUnwrap(extensions.first)
        XCTAssertEqual(sent.groupID, groupID)
        let payload = try payload(ofJWS: sent.jws)
        XCTAssertEqual(payload["productId"] as? String, "app.commoncam.extension")
        XCTAssertEqual((payload["appAccountToken"] as? String)?.lowercased(), groupID)
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    func testAnExtensionTheAPIRejectedIsRedeemedLaterForTheSameGroup() async throws {
        // e.g. 400 "not ended yet" or offline: the payment stays unfinished.
        _ = try? await extender(failingWith: APIError(statusCode: 400)).purchase(for: groupID)
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await extender().extendUnfinished()

        XCTAssertEqual(groups.map(\.id), [groupID])
        XCTAssertEqual(extensions.map(\.groupID), [groupID])
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    func testLeavesOtherUnfinishedPurchasesAlone() async throws {
        let pocketGroup = EventGroup(
            id: groupID, tier: "pocket", state: "Active", peopleCap: 10, storageCapBytes: 1, startsAt: .now, endsAt: .now
        )
        _ = try? await GroupPurchaser(apply: { _, _ in throw APIError(statusCode: 500) }, buy: buyInSession)
            .purchase(.addOn(.day), for: pocketGroup)
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await extender().extendUnfinished()

        XCTAssertEqual(groups, [])
        XCTAssertTrue(extensions.isEmpty)
        let unfinished = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinished, 1)
    }
}
