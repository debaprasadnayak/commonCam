import Foundation
import Testing
@testable import CommonCamKit

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
            recorded.httpBody = body
        }
        Self.requests.append(recorded)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let groupJSON = """
{"id":"g1","tier":"taster","state":"Active","peopleCap":4,"storageCapBytes":1073741824,
 "startsAt":"2026-10-30T08:00:00.000Z","endsAt":"2026-10-31T08:00:00.000Z"}
"""

private let tasterGroup = EventGroup(
    id: "g1", tier: "taster", state: "Active", peopleCap: 4, storageCapBytes: 1_073_741_824,
    startsAt: Date(timeIntervalSince1970: 1_793_347_200), endsAt: Date(timeIntervalSince1970: 1_793_433_600)
)

private let memberJSON = """
{"id":"m1","displayName":"Dancing Otter","colour":"#FF8800","role":"guest",
 "consentAcceptedAt":"2026-10-30T08:00:00.000Z","joinedAt":"2026-10-30T08:00:00.000Z"}
"""

private let otter = Member(
    id: "m1", displayName: "Dancing Otter", colour: "#FF8800", role: "guest",
    consentAcceptedAt: Date(timeIntervalSince1970: 1_793_347_200), joinedAt: Date(timeIntervalSince1970: 1_793_347_200)
)

@Suite(.serialized) struct APIClientTests {
    let client: APIClient

    init() {
        StubURLProtocol.requests = []
        StubURLProtocol.statusCode = 200
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let store = InMemoryTokenStore()
        store.token = "device-token"
        client = APIClient(
            baseURL: URL(string: "https://api.test")!,
            identity: DeviceIdentity(store: store),
            session: URLSession(configuration: config)
        )
    }

    @Test func createsATasterGroupWithTheDeviceToken() async throws {
        StubURLProtocol.statusCode = 201
        StubURLProtocol.responseBody = Data(groupJSON.utf8)

        let group = try await client.createTasterGroup()

        #expect(group == tasterGroup)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
        #expect(request.httpBody == Data(#"{"tier":"taster"}"#.utf8))
    }

    @Test func listsMyGroupsWithTheDeviceToken() async throws {
        StubURLProtocol.responseBody = Data("[\(groupJSON)]".utf8)

        let groups = try await client.myGroups()

        #expect(groups == [tasterGroup])
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
    }

    @Test func fetchesTheHostsInvite() async throws {
        StubURLProtocol.responseBody = Data(#"{"qrToken":"tok","joinUrl":"https://api.test/join/tok","joiningPaused":false}"#.utf8)

        let invite = try await client.invite(for: "g1")

        #expect(invite == Invite(qrToken: "tok", joinUrl: URL(string: "https://api.test/join/tok")!, joiningPaused: false))
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/invite")
    }

    @Test func joinsWithNameColourAndConsent() async throws {
        StubURLProtocol.statusCode = 201
        StubURLProtocol.responseBody = Data("""
        {"group":\(groupJSON),"member":\(memberJSON)}
        """.utf8)

        let membership = try await client.join(qrToken: "tok", displayName: "Dancing Otter", colour: "#FF8800", consentAccepted: true)

        #expect(membership == Membership(group: tasterGroup, member: otter))
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/join")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["qrToken"] as? String == "tok")
        #expect(body?["displayName"] as? String == "Dancing Otter")
        #expect(body?["colour"] as? String == "#FF8800")
        #expect(body?["consent"] as? Bool == true)
    }

    @Test func listsAGroupsMembers() async throws {
        StubURLProtocol.responseBody = Data("[\(memberJSON)]".utf8)

        let members = try await client.members(of: "g1")

        #expect(members == [otter])
        #expect(StubURLProtocol.requests.first?.url?.absoluteString == "https://api.test/groups/g1/members")
    }

    @Test func surfacesAFullGroupAsItsStatusCode() async throws {
        StubURLProtocol.statusCode = 409
        StubURLProtocol.responseBody = Data()

        await #expect(throws: APIError(statusCode: 409)) {
            try await client.join(qrToken: "tok", displayName: "X", colour: "#000000", consentAccepted: true)
        }
    }

    @Test func pausesJoining() async throws {
        StubURLProtocol.responseBody = Data(#"{"joiningPaused":true}"#.utf8)

        let paused = try await client.setJoiningPaused(true, for: "g1")

        #expect(paused)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/joining")
        #expect(request.httpBody == Data(#"{"paused":true}"#.utf8))
    }

    @Test func rotatesTheQR() async throws {
        StubURLProtocol.responseBody = Data(#"{"qrToken":"new","joinUrl":"https://api.test/join/new","joiningPaused":true}"#.utf8)

        let invite = try await client.rotateInvite(for: "g1")

        #expect(invite == Invite(qrToken: "new", joinUrl: URL(string: "https://api.test/join/new")!, joiningPaused: true))
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/invite/rotate")
    }

    @Test(arguments: [(MemberAction.remove, "remove"), (.ban, "ban"), (.makeCoHost, "co-host")])
    func appliesAMemberAction(action: MemberAction, path: String) async throws {
        StubURLProtocol.statusCode = 204
        StubURLProtocol.responseBody = Data()

        try await client.perform(action, on: "m1", in: "g1")

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/members/m1/\(path)")
    }

    @Test func failsOnAnErrorStatus() async throws {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseBody = Data()

        await #expect(throws: APIError.self) { try await client.myGroups() }
    }
}
