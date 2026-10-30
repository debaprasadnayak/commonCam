import StoreKit
import StoreKitTest
import XCTest

/// Base class for StoreKitTest-backed tests. Each test gets a fresh `SKTestSession` (no dialogs, no
/// Ask to Buy) and starts and ends with no unfinished transactions.
///
/// Tests finish transactions rather than calling `clearTransactions()`: that call returns before
/// storekitd deletes anything, and the transaction-history sync the delete triggers can overlap the
/// next test's purchase, leaving `Transaction.unfinished` without it for ~15 s.
@MainActor
class StoreKitTestCase: XCTestCase {
    private(set) var session: SKTestSession!

    override func setUp() async throws {
        try await super.setUp()
        // shortcut: the .storekit file is Xcode 27's format and iOS 26 runtimes (GitHub's newest runner) load no products, so StoreKit tests only run on iOS 27+; remove this skip once CI has Xcode 27.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            throw XCTSkip("StoreKit test configuration needs an iOS 27 runtime")
        }
        session = try SKTestSession(configurationFileNamed: "CommonCam")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.interruptedPurchasesEnabled = false
        let leftover = await finishAllUnfinished()
        XCTAssertEqual(leftover, 0, "StoreKit state leaked in from an earlier test")
    }

    override func tearDown() async throws {
        guard session != nil else { return try await super.tearDown() }
        let leftover = await finishAllUnfinished()
        XCTAssertEqual(leftover, 0, "Could not finish this test's transactions")
        session = nil
        try await super.tearDown()
    }

    /// Finishes every unfinished transaction; returns how many StoreKit still lists afterwards.
    private func finishAllUnfinished() async -> Int {
        for await verification in Transaction.unfinished {
            await verification.unsafePayloadValue.finish()
        }
        return await unfinishedCount(settlingAt: 0)
    }

    /// Purchases go through the test session instead of `Product.purchase`. In the first test-host
    /// process on a fresh simulator the app's StoreKit client connects before `SKTestSession` has
    /// saved its configuration, so `Product.purchase` is sent to the real Sandbox and waits forever
    /// for an Apple Account sign-in (later processes are fine). `buyProduct` is served by the
    /// StoreKit test server in every process and honours the same options (e.g. `appAccountToken`).
    func buyInSession(_ product: Product, _ options: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        let transaction = try await session.buyProduct(identifier: product.id, options: options)
        // Hand over the transaction only once StoreKit lists it as unfinished, as after a real
        // purchase; finishing it earlier races storekitd's post-purchase sync, which then re-caches it
        // as unfinished for good.
        for _ in 0..<300 {
            for await verification in Transaction.unfinished where verification.unsafePayloadValue.id == transaction.id {
                return .success(verification)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw StoreKitTestError.purchaseNotRecorded(product.id)
    }

    /// StoreKit applies purchases and `finish()` asynchronously (seconds on a loaded machine), so poll for up to 30 s.
    func unfinishedCount(settlingAt expected: Int) async -> Int {
        var count = -1
        for _ in 0..<300 {
            count = 0
            for await _ in Transaction.unfinished { count += 1 }
            if count == expected { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return count
    }

    /// The decoded payload of a signed transaction (no signature check).
    func payload(ofJWS jws: String) throws -> [String: Any] {
        let parts = jws.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: payload)))
        return try XCTUnwrap(json as? [String: Any])
    }
}

enum StoreKitTestError: Error {
    case purchaseNotRecorded(String)
}
