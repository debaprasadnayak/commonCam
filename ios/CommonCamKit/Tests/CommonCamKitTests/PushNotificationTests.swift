import Foundation
import Testing
@testable import CommonCamKit

// Shares the serialized suite, since StubURLProtocol state is static.
extension APIClientTests {
    @Test func registersTheAPNsDeviceTokenAsHex() async throws {
        StubURLProtocol.statusCode = 204
        StubURLProtocol.responseBody = Data()

        try await client.registerPushToken(Data([0x00, 0xAB, 0x7F, 0xFF]))

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://api.test/devices/push-token")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["token"] as? String == "00ab7fff")
    }
}
