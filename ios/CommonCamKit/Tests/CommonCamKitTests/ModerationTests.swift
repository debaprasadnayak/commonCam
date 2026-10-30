import Foundation
import Testing
@testable import CommonCamKit

private let reportJSON = """
{"id":"r1","itemId":"i1","memberId":null,"reason":"Not \\"ok\\"","status":"open","createdAt":"2026-10-30T08:00:00.000Z"}
"""

private let hiddenItemJSON = """
{"id":"i1","type":"photo","contentType":"image/heic","bytes":4,"createdAt":"2026-10-30T08:00:00.000Z",
 "contributor":{"memberId":"m1","displayName":"Dancing Otter","colour":"#FF8800"},
 "downloadUrl":"https://api.test/media/groups/g1/i1?exp=1&sig=s","downloadUrlExpiresAt":"2026-10-30T08:15:00.000Z","canDelete":true,"hidden":true}
"""

// Moderation lives in its own file but shares the serialized suite, since StubURLProtocol state is static.
extension APIClientTests {
    @Test func reportsAnItemWithItsReason() async throws {
        StubURLProtocol.statusCode = 201
        StubURLProtocol.responseBody = Data(reportJSON.utf8)

        let report = try await client.reportItem("i1", in: "g1", reason: #"Not "ok""#)

        #expect(report.id == "r1")
        #expect(report.itemId == "i1")
        #expect(report.reason == #"Not "ok""#)
        #expect(report.isOpen)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/items/i1/report")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["reason"] as? String == #"Not "ok""#)
    }

    @Test func reportsAMember() async throws {
        StubURLProtocol.statusCode = 201
        StubURLProtocol.responseBody = Data(reportJSON.utf8)

        _ = try await client.reportMember("m1", in: "g1", reason: "Rude")

        #expect(StubURLProtocol.requests.first?.url?.absoluteString == "https://api.test/groups/g1/members/m1/report")
    }

    @Test func blocksAndUnblocksAMember() async throws {
        StubURLProtocol.statusCode = 204
        StubURLProtocol.responseBody = Data()

        try await client.block(memberID: "m1", in: "g1")
        try await client.unblock(memberID: "m1", in: "g1")

        #expect(StubURLProtocol.requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(Set(StubURLProtocol.requests.map(\.url?.absoluteString)) == ["https://api.test/groups/g1/members/m1/block"])
    }

    @Test func listsOpenReportsWithTheReportedItem() async throws {
        StubURLProtocol.responseBody = Data("[\(reportJSON.dropLast()),\"item\":\(hiddenItemJSON)}]".utf8)

        let reports = try await client.openReports(of: "g1")

        #expect(reports.count == 1)
        #expect(reports.first?.item?.id == "i1")
        #expect(reports.first?.item?.isHidden == true)
        #expect(reports.first?.member == nil)
        #expect(StubURLProtocol.requests.first?.url?.absoluteString == "https://api.test/groups/g1/reports")
    }

    @Test(arguments: [(ReportDecision.restore, "restore"), (.delete, "delete")])
    func reviewsAReport(decision: ReportDecision, path: String) async throws {
        StubURLProtocol.responseBody = Data(reportJSON.replacingOccurrences(of: #""open""#, with: #""restored""#).utf8)

        let report = try await client.review("r1", in: "g1", decision)

        #expect(!report.isOpen)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.test/groups/g1/reports/r1/\(path)")
    }

    @Test func treatsGalleryItemsWithoutTheHiddenFlagAsVisible() async throws {
        let visible = hiddenItemJSON.replacingOccurrences(of: #","hidden":true"#, with: "")
        StubURLProtocol.responseBody = Data("[\(visible),\(hiddenItemJSON)]".utf8)

        let items = try await client.gallery(of: "g1")

        #expect(items.map(\.isHidden) == [false, true])
    }

    @Test func publishesATakedownContactEmail() {
        #expect(Contact.takedownEmail.contains("@"))
        #expect(Contact.takedownMailURL.absoluteString == "mailto:\(Contact.takedownEmail)")
    }
}
