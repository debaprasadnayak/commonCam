import Testing
@testable import CommonCamKit

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    var token: String?
    func load() throws -> String? { token }
    func save(_ token: String) throws { self.token = token }
}

@Suite struct DeviceIdentityTests {
    @Test func mintsAndStoresATokenOnFirstLaunch() throws {
        let store = InMemoryTokenStore()

        let token = try DeviceIdentity(store: store).token()

        #expect(token.count >= 43)
        #expect(store.token == token)
    }

    @Test func reusesTheStoredTokenAfterReinstall() throws {
        let store = InMemoryTokenStore()
        let first = try DeviceIdentity(store: store).token()

        let afterReinstall = try DeviceIdentity(store: store).token()

        #expect(afterReinstall == first)
    }

    @Test func differentDevicesGetDifferentTokens() throws {
        let a = try DeviceIdentity(store: InMemoryTokenStore()).token()
        let b = try DeviceIdentity(store: InMemoryTokenStore()).token()

        #expect(a != b)
    }
}
