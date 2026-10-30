import CommonCamKit
import Security
import XCTest

final class KeychainTokenStoreTests: XCTestCase {
    private let service = "app.commoncam.tests.\(UUID().uuidString)"

    override func tearDown() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ] as CFDictionary)
    }

    func testIsEmptyBeforeATokenIsSaved() throws {
        XCTAssertNil(try KeychainTokenStore(service: service).load())
    }

    func testTokenSurvivesAFreshStoreInstanceLikeAReinstall() throws {
        let token = try DeviceIdentity(store: KeychainTokenStore(service: service)).token()

        let afterReinstall = try DeviceIdentity(store: KeychainTokenStore(service: service)).token()

        XCTAssertEqual(afterReinstall, token)
    }

    func testTokenIsStoredAsAnICloudSyncedItem() throws {
        try KeychainTokenStore(service: service).save("t")

        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess)
    }
}
