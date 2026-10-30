import CommonCamKit
import StoreKit
import StoreKitTest
import XCTest
@testable import CommonCam

@MainActor
final class GroupExtenderTests: XCTestCase {
    private let groupID = "0b6f7c1e-3a5d-4c2e-9f10-5d2b8a7e4c11"
    private var session: SKTestSession!
    private var extensions: [(groupID: String, jws: String)] = []

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "CommonCam")
        session.disableDialogs = true
        session.clearTransactions()
        extensions = []
    }

    private func extender(failingWith error: Error? = nil) -> GroupExtender {
        GroupExtender { [unowned self] groupID, jws in
            if let error { throw error }
            extensions.append((groupID, jws))
            return EventGroup(id: groupID, tier: "taster", state: "Active", peopleCap: 4, storageCapBytes: 1, startsAt: .now, endsAt: .now)
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
        _ = try? await extender(failingWith: APIError(statusCode: 500)).purchase(for: groupID)
        let unfinishedAfterFailure = await unfinishedCount(settlingAt: 1)
        XCTAssertEqual(unfinishedAfterFailure, 1)

        let groups = await extender().extendUnfinished()

        XCTAssertEqual(groups.map(\.id), [groupID])
        let unfinished = await unfinishedCount(settlingAt: 0)
        XCTAssertEqual(unfinished, 0)
    }

    private func payload(ofJWS jws: String) throws -> [String: Any] {
        let parts = jws.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: payload)))
        return try XCTUnwrap(json as? [String: Any])
    }
}
