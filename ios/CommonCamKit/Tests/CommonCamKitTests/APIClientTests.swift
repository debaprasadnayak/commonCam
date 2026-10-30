import Foundation
import Testing
@testable import CommonCamKit

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200
    /// When non-empty, each request consumes the next (status, body) instead of `statusCode`/`responseBody`.
    nonisolated(unsafe) static var queue: [(Int, Data)] = []

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
        let (status, body) = Self.queue.isEmpty ? (Self.statusCode, Self.responseBody) : Self.queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let groupJSON = """
{"id":"g1","tier":"taster","state":"Active","peopleCap":4,"storageCapBytes":1073741824,"storageUsedBytes":0,
 "startsAt":"2026-10-30T08:00:00.000Z","endsAt":"2026-10-31T08:00:00.000Z"}
"""

private let tasterGroup = EventGroup(
    id: "g1", tier: "taster", state: "Active", peopleCap: 4, storageCapBytes: 1_073_741_824, storageUsedBytes: 0,
    startsAt: Date(timeIntervalSince1970: 1_793_347_200), endsAt: Date(timeIntervalSince1970: 1_793_433_600)
)

private let memberJSON = """
{"id":"m1","displayName":"Dancing Otter","colour":"#FF8800","role":"guest","status":"active",
 "consentAcceptedAt":"2026-10-30T08:00:00.000Z","joinedAt":"2026-10-30T08:00:00.000Z"}
"""

private let itemJSON = """
{"id":"i1","type":"photo","contentType":"image/heic","bytes":4,"createdAt":"2026-10-30T08:00:00.000Z",
 "contributor":{"memberId":"m1","displayName":"Dancing Otter","colour":"#FF8800"},
 "downloadUrl":"https://api.test/media/groups/g1/i1?exp=1&sig=s","downloadUrlExpiresAt":"2026-10-30T08:15:00.000Z"}
"""

private let otterPhoto = GalleryItem(
    id: "i1", type: "photo", contentType: "image/heic", bytes: 4, createdAt: Date(timeIntervalSince1970: 1_793_347_200),
    contributor: Contributor(memberId: "m1", displayName: "Dancing Otter", colour: "#FF8800"),
    downloadUrl: URL(string: "https://api.test/media/groups/g1/i1?exp=1&sig=s")!,
    downloadUrlExpiresAt: Date(timeIntervalSince1970: 1_793_348_100)
)

private let otter = Member(
    id: "m1", displayName: "Dancing Otter", colour: "#FF8800", role: "guest", status: "active",
    consentAcceptedAt: Date(timeIntervalSince1970: 1_793_347_200), joinedAt: Date(timeIntervalSince1970: 1_793_347_200)
)

@Suite(.serialized) struct APIClientTests {
    let client: APIClient

    init() {
        StubURLProtocol.requests = []
        StubURLProtocol.statusCode = 200
        StubURLProtocol.queue = []
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

    @Test func joinsWithAPinInsteadOfAQRToken() async throws {
        StubURLProtocol.statusCode = 201
        StubURLProtocol.responseBody = Data("""
        {"group":\(groupJSON),"member":\(memberJSON)}
        """.utf8)

        let membership = try await client.join(pin: "K7MQ2X", displayName: "Dancing Otter", colour: "#FF8800", consentAccepted: true)

        #expect(membership == Membership(group: tasterGroup, member: otter))
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.test/join")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["pin"] as? String == "K7MQ2X")
        #expect(body?["qrToken"] == nil)
        #expect(body?["consent"] as? Bool == true)
    }

    @Test func showsThatThePinIsOffByDefault() async throws {
        StubURLProtocol.responseBody = Data(#"{"pin":null}"#.utf8)

        let pin = try await client.pin(for: "g1")

        #expect(pin == nil)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/pin")
    }

    @Test func turnsOnOrRotatesThePin() async throws {
        StubURLProtocol.responseBody = Data(#"{"pin":"K7MQ2X"}"#.utf8)

        let pin = try await client.rotatePin(for: "g1")

        #expect(pin == "K7MQ2X")
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/pin")
    }

    @Test func turnsThePinOff() async throws {
        StubURLProtocol.responseBody = Data(#"{"pin":null}"#.utf8)

        try await client.turnOffPin(for: "g1")

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/pin")
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

    @Test func reportsAJoinAwaitingApprovalAsPending() async throws {
        StubURLProtocol.statusCode = 202
        StubURLProtocol.responseBody = Data("""
        {"group":\(groupJSON),"member":\(memberJSON.replacingOccurrences(of: #""active""#, with: #""pending""#))}
        """.utf8)

        let membership = try await client.join(qrToken: "tok", displayName: "Dancing Otter", colour: "#FF8800", consentAccepted: true)

        #expect(membership.isPending)
    }

    @Test func readsAndSetsTheApprovalToggle() async throws {
        StubURLProtocol.responseBody = Data(#"{"approvalRequired":true}"#.utf8)

        #expect(try await client.setApprovalRequired(true, for: "g1") == true)
        #expect(try await client.approvalRequired(for: "g1") == true)

        let put = StubURLProtocol.requests[0]
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.absoluteString == "https://api.test/groups/g1/approval")
        #expect(put.httpBody == Data(#"{"approvalRequired":true}"#.utf8))
        #expect(StubURLProtocol.requests[1].httpMethod == "GET")
    }

    @Test func listsPendingRequests() async throws {
        StubURLProtocol.responseBody = Data("[\(memberJSON)]".utf8)

        #expect(try await client.pendingMembers(of: "g1") == [otter])
        #expect(StubURLProtocol.requests.first?.url?.absoluteString == "https://api.test/groups/g1/pending")
    }

    @Test func approvesAndRejectsRequests() async throws {
        StubURLProtocol.responseBody = Data(memberJSON.utf8)
        #expect(try await client.approve(memberID: "m1", in: "g1") == otter)

        StubURLProtocol.statusCode = 204
        StubURLProtocol.responseBody = Data()
        try await client.reject(memberID: "m2", in: "g1")

        #expect(StubURLProtocol.requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(StubURLProtocol.requests.map(\.url?.absoluteString) == [
            "https://api.test/groups/g1/members/m1/approve", "https://api.test/groups/g1/members/m2/reject",
        ])
    }

    @Test func failsOnAnErrorStatus() async throws {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.responseBody = Data()

        await #expect(throws: APIError.self) { try await client.myGroups() }
    }

    @Test func sharesAPhotoByUploadingTheOriginalUntouchedThenConfirmingIt() async throws {
        let original = Data([0x00, 0x01, 0xFE, 0xFF])
        StubURLProtocol.queue = [
            (201, Data(#"{"itemId":"i1","uploadUrl":"https://api.test/media/groups/g1/i1?sig=s","expiresAt":"2026-10-30T08:15:00.000Z"}"#.utf8)),
            (200, Data()),
            (201, Data(itemJSON.utf8)),
        ]

        let item = try await client.share(CapturedPhoto(data: original, format: .heic), in: "g1")

        #expect(item == otterPhoto)
        let requests = StubURLProtocol.requests
        try #require(requests.count == 3)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.absoluteString == "https://api.test/groups/g1/uploads")
        let ask = try JSONSerialization.jsonObject(with: try #require(requests[0].httpBody)) as? [String: Any]
        #expect(ask?["bytes"] as? Int == 4)
        #expect(ask?["contentType"] as? String == "image/heic")
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[1].url?.absoluteString == "https://api.test/media/groups/g1/i1?sig=s")
        #expect(requests[1].httpBody == original)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[2].httpMethod == "POST")
        #expect(requests[2].url?.absoluteString == "https://api.test/groups/g1/items")
        let confirm = try JSONSerialization.jsonObject(with: try #require(requests[2].httpBody)) as? [String: Any]
        #expect(confirm?["itemId"] as? String == "i1")
    }

    @Test func doesNotUploadWhenTheGroupRefusesTheUpload() async throws {
        StubURLProtocol.queue = [(413, Data())]

        await #expect(throws: APIError(statusCode: 413)) {
            try await client.share(CapturedPhoto(data: Data([1]), format: .heic), in: "g1")
        }
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test func listsTheSharedGallery() async throws {
        StubURLProtocol.responseBody = Data("[\(itemJSON)]".utf8)

        let items = try await client.gallery(of: "g1")

        #expect(items == [otterPhoto])
        #expect(StubURLProtocol.requests.first?.url?.absoluteString == "https://api.test/groups/g1/items")
    }

    @Test func drivesAResumableUploadThroughStartPlanCompleteAndConfirm() async throws {
        StubURLProtocol.queue = [
            (201, Data(#"{"itemId":"i1","partSize":5242880,"partCount":2}"#.utf8)),
            (200, Data(#"{"uploadedParts":[1],"parts":[{"partNumber":2,"url":"https://api.test/media-parts/i1/2?sig=s"}],"expiresAt":"2026-10-30T08:15:00.000Z"}"#.utf8)),
            (204, Data()),
            (201, Data(itemJSON.utf8)),
        ]

        let upload = try await client.startUpload(bytes: 5_242_890, contentType: "image/heic", in: "g1")
        let plan = try await client.partPlan(itemID: upload.itemId, in: "g1")
        try await client.completeUpload(itemID: "i1", in: "g1")
        let item = try await client.confirmUpload(itemID: "i1", in: "g1")

        #expect(upload == MultipartUpload(itemId: "i1", partSize: 5_242_880, partCount: 2))
        #expect(plan.uploadedParts == [1])
        #expect(plan.parts == [PartURL(partNumber: 2, url: URL(string: "https://api.test/media-parts/i1/2?sig=s")!)])
        #expect(item == otterPhoto)
        let requests = StubURLProtocol.requests
        #expect(requests.map(\.url?.path) == ["/groups/g1/multipart", "/groups/g1/multipart/i1/parts", "/groups/g1/multipart/i1/complete", "/groups/g1/items"])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        let ask = try JSONSerialization.jsonObject(with: try #require(requests[0].httpBody)) as? [String: Any]
        #expect(ask?["bytes"] as? Int == 5_242_890)
    }

    @Test func backgroundTransportPutsThePartFileWithoutTheDeviceToken() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "part-\(UUID().uuidString)")
        try Data([9, 8, 7]).write(to: file)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let transport = BackgroundUploadTransport(configuration: config)

        try await transport.upload(file: file, to: URL(string: "https://api.test/media-parts/i1/1?sig=s")!, taskID: "a#1")

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.httpBody == Data([9, 8, 7]))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func backgroundTransportReportsARefusedPart() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "part-\(UUID().uuidString)")
        try Data([1]).write(to: file)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.statusCode = 403

        await #expect(throws: APIError(statusCode: 403)) {
            try await BackgroundUploadTransport(configuration: config)
                .upload(file: file, to: URL(string: "https://api.test/media-parts/i1/1")!, taskID: "b#1")
        }
    }
}
