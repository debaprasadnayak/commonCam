import CommonCamKit
import StoreKit
import XCTest
@testable import CommonCam

@MainActor
final class PurchaseRouterTests: StoreKitTestCase {
    /// `SKTestSession.buyProduct` completes a purchase outside the app's own `purchase(...)` call, as an
    /// approved Ask to Buy or a purchase on another device does. (It skips Ask to Buy itself, and Ask to Buy
    /// via `Product.purchase` hangs on fresh simulators, see `buyInSession`.)
    func testAPurchaseCompletedOutsideTheAppIsActivatedWhileTheAppRuns() async throws {
        var activated: [PaidTier] = []
        let tiers = TierPurchaser(activate: { tier, _ in
            activated.append(tier)
            return EventGroup(id: "g1", tier: tier.rawValue, state: "Active", peopleCap: 25, storageCapBytes: 1, startsAt: .now, endsAt: .now)
        })
        let (groups, delivered) = AsyncStream.makeStream(of: EventGroup.self)
        let listener = Task { await PurchaseRouter(handlers: [tiers.handle]).processUpdates { delivered.yield($0) } }
        defer { listener.cancel() }
        let timeout = Task { try await Task.sleep(for: .seconds(120)); delivered.finish() }
        defer { timeout.cancel() }

        // `Transaction.updates` only reports transactions made after its iteration has subscribed (no ready signal).
        try await Task.sleep(for: .seconds(2))
        _ = try await session.buyProduct(identifier: PaidTier.party.productID)

        var iterator = groups.makeAsyncIterator()
        let group = await iterator.next()
        XCTAssertEqual(group?.tier, "party")
        XCTAssertEqual(activated, [.party])
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }
}
