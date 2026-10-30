import CommonCamKit
import StoreKit
import StoreKitTest
import XCTest
@testable import CommonCam

@MainActor
final class TierPurchaserTests: XCTestCase {
    private var session: SKTestSession!
    private var activations: [(tier: PaidTier, jws: String)] = []

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "CommonCam")
        session.disableDialogs = true
        session.clearTransactions()
        activations = []
    }

    private func purchaser(failingWith error: Error? = nil) -> TierPurchaser {
        TierPurchaser { [unowned self] tier, jws in
            if let error { throw error }
            activations.append((tier, jws))
            return EventGroup(
                id: "g1", tier: tier.rawValue, state: "Active", peopleCap: 25, storageCapBytes: 1,
                startsAt: .now, endsAt: .now
            )
        }
    }

    /// StoreKit applies purchases and `finish()` asynchronously (slow on a loaded machine), so poll briefly.
    private func unfinishedCount(settlingAt expected: Int) async -> Int {
        var count = -1
        for _ in 0..<50 {
            count = 0
            for await _ in Transaction.unfinished { count += 1 }
            if count == expected { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return count
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

        let groups = await purchaser().activateUnfinished()

        XCTAssertEqual(groups.map(\.tier), ["festival"])
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    func testATransactionTheServerAlreadyUsedIsFinished() async throws {
        _ = try? await purchaser(failingWith: APIError(statusCode: 500)).purchase(.pocket)
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await purchaser(failingWith: APIError(statusCode: 409)).activateUnfinished()

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
