import Foundation
import Testing
@testable import CommonCamKit

private let groupID = "0b6f7c1e-3a5d-4c2e-9f10-5d2b8a7e4c11"

private func groupJSON(state: String, graceEndsAt: String?) -> Data {
    let grace = graceEndsAt.map { "\"\($0)\"" } ?? "null"
    return Data("""
    {"id":"\(groupID)","tier":"taster","state":"\(state)","peopleCap":4,"storageCapBytes":1073741824,"storageUsedBytes":0,"storageLevel":"ok",
     "startsAt":"2026-10-30T08:00:00.000Z","endsAt":"2026-10-31T08:00:00.000Z","graceEndsAt":\(grace)}
    """.utf8)
}

// Shares the serialized suite, since StubURLProtocol state is static.
extension APIClientTests {
    @Test func aGroupInGraceIsReadOnlyUntilItsGraceEnds() async throws {
        StubURLProtocol.responseBody = Data("[\(String(decoding: groupJSON(state: "Grace", graceEndsAt: "2026-11-14T08:00:00.000Z"), as: UTF8.self))]".utf8)

        let group = try #require(try await client.myGroups().first)

        #expect(group.isReadOnly)
        #expect(group.canExtend)
        #expect(group.graceEndsAt == Date(timeIntervalSince1970: 1_794_643_200))
    }

    @Test func anActiveGroupHasNoGraceEnd() async throws {
        StubURLProtocol.responseBody = Data("[\(String(decoding: groupJSON(state: "Active", graceEndsAt: nil), as: UTF8.self))]".utf8)

        let group = try #require(try await client.myGroups().first)

        #expect(!group.isReadOnly)
        #expect(!group.canExtend)
        #expect(group.graceEndsAt == nil)
    }

    @Test func aDeletedGroupIsReadOnlyAndCannotBeExtended() async throws {
        StubURLProtocol.responseBody = Data("[\(String(decoding: groupJSON(state: "Deleted", graceEndsAt: nil), as: UTF8.self))]".utf8)

        let group = try #require(try await client.myGroups().first)

        #expect(group.isReadOnly)
        #expect(!group.canExtend)
    }

    @Test func extendsAGroupWithTheSignedTransaction() async throws {
        StubURLProtocol.responseBody = groupJSON(state: "Active", graceEndsAt: nil)

        let group = try await client.extendGroup(groupID, signedTransaction: "jws.payload.sig")

        #expect(group.state == "Active")
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups/\(groupID)/extend")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["signedTransaction"] as? String == "jws.payload.sig")
    }
}

@Test func theExtensionPurchaseCarriesItsGroupAsTheAppAccountToken() throws {
    #expect(GroupExtension.productID == "app.commoncam.extension")
    let token = try #require(GroupExtension.appAccountToken(forGroup: groupID))
    // UUID prints upper-case; the API's group ids are lower-case.
    #expect(GroupExtension.groupID(fromAppAccountToken: token) == groupID)
    #expect(GroupExtension.appAccountToken(forGroup: "not-a-uuid") == nil)
}
