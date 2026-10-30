import CommonCamKit
import StoreKit
import XCTest
@testable import CommonCam

@MainActor
final class TierPurchaserTests: StoreKitTestCase {
    private var activations: [(tier: PaidTier, jws: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        activations = []
    }

    private func purchaser(failingWith error: Error? = nil) -> TierPurchaser {
        TierPurchaser(activate: { [unowned self] tier, jws in
            if let error { throw error }
            activations.append((tier, jws))
            return EventGroup(
                id: "g1", tier: tier.rawValue, state: "Active", peopleCap: 25, storageCapBytes: 1,
                startsAt: .now, endsAt: .now
            )
        }, buy: buyInSession)
    }

    func testLoadsAProductForEveryPaidTier() async throws {
        let products = try await purchaser().products()

        XCTAssertEqual(Set(products.keys), Set(PaidTier.allCases))
        XCTAssertEqual(products[.party]?.displayName, "Party")
    }

    func testBuyingPartySendsTheSignedTransactionToTheAPIAndFinishesIt() async throws {
        let group = try await purchaser().purchase(.party)

        XCTAssertEqual(group?.tier, "party")
        let activation = try XCTUnwrap(activations.first)
        XCTAssertEqual(activation.tier, .party)
        XCTAssertEqual(try productID(inJWS: activation.jws), "app.commoncam.tier.party")
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    func testAPurchaseTheAPIRejectedStaysUnfinishedAndIsActivatedLater() async throws {
        do {
            _ = try await purchaser(failingWith: APIError(statusCode: 500)).purchase(.festival)
            XCTFail("Expected the activation error")
        } catch {}
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await PurchaseRouter(handlers: [purchaser().handle]).processUnfinished()

        XCTAssertEqual(groups.map(\.tier), ["festival"])
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    func testATransactionTheServerAlreadyUsedIsFinished() async throws {
        _ = try? await purchaser(failingWith: APIError(statusCode: 500)).purchase(.pocket)
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await PurchaseRouter(handlers: [purchaser(failingWith: APIError(statusCode: 409)).handle]).processUnfinished()

        XCTAssertEqual(groups, [])
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    private func productID(inJWS jws: String) throws -> String? {
        let parts = jws.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: payload)))
        return (json as? [String: Any])?["productId"] as? String
    }
}
