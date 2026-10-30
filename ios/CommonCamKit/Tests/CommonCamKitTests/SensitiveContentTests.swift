import Foundation
import Testing
@testable import CommonCamKit

/// Stands in for Apple's analyser: a fixed answer, switched off, or failing.
struct FakeAnalyzer: SensitiveContentAnalyzer {
    var isEnabled = true
    var verdict: Bool = false
    var error: Error?
    let calls = Counter()

    func isSensitive(imageAt url: URL) async throws -> Bool {
        calls.increment()
        if let error { throw error }
        return verdict
    }
}

final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}

private func emptyDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SensitiveContentTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let shot = CapturedPhoto(data: Data((0..<25).map { UInt8($0) }), format: .heic)

struct SensitiveContentTests {
    let directory: URL
    let server = FakeServer(partSize: 10)
    let transport: FakeTransport

    init() throws {
        directory = try emptyDirectory()
        transport = FakeTransport(server: server)
    }

    private func share(with analyzer: SensitiveContentAnalyzer?) async throws -> Bool? {
        let queue = UploadQueue(directory: directory, service: server, transport: transport, analyzer: analyzer)
        try await queue.enqueue(shot, in: "g1")
        #expect(await queue.run().map(\.id) == ["item-1"])
        return await server.flagged["item-1"]
    }

    @Test func aShotTheAnalyzerFlagsIsConfirmedAsSensitive() async throws {
        #expect(try await share(with: FakeAnalyzer(verdict: true)) == true)
    }

    @Test func aCleanShotIsConfirmedUnflagged() async throws {
        #expect(try await share(with: FakeAnalyzer(verdict: false)) == false)
    }

    @Test func sharesUnflaggedWhenAnalysisIsSwitchedOffWithoutAnalysing() async throws {
        let analyzer = FakeAnalyzer(isEnabled: false, verdict: true)

        #expect(try await share(with: analyzer) == false)
        #expect(analyzer.calls.value == 0)
    }

    @Test func sharesUnflaggedWhenAnalysisFails() async throws {
        #expect(try await share(with: FakeAnalyzer(verdict: true, error: CocoaError(.fileReadCorruptFile))) == false)
    }

    @Test func sharesUnflaggedWithoutAnAnalyzer() async throws {
        #expect(try await share(with: nil) == false)
    }

    @Test func analysesEachShotOnceEvenWhenConfirmIsRetriedAfterRelaunch() async throws {
        let analyzer = FakeAnalyzer(verdict: true)
        let first = UploadQueue(directory: directory, service: server, transport: transport, analyzer: analyzer)
        try await first.enqueue(shot, in: "g1")
        await server.refuseConfirm(with: URLError(.timedOut))
        #expect(await first.run().isEmpty)

        await server.refuseConfirm(with: nil)
        let relaunched = UploadQueue(directory: directory, service: server, transport: transport, analyzer: FakeAnalyzer(verdict: false))
        #expect(await relaunched.run().map(\.id) == ["item-1"])

        #expect(analyzer.calls.value == 1)
        #expect(await server.flagged["item-1"] == true)
    }
}

extension APIClientTests {
    @Test func confirmSendsTheSensitiveFlag() async throws {
        StubURLProtocol.statusCode = 201
        StubURLProtocol.responseBody = Data("""
        {"id":"i1","type":"photo","contentType":"image/heic","bytes":4,"createdAt":"2026-10-30T08:00:00.000Z",
         "contributor":{"memberId":null,"displayName":"Host","colour":"#8E8E93"},
         "downloadUrl":"https://api.test/media/x","downloadUrlExpiresAt":"2026-10-30T08:15:00.000Z","canDelete":true,"hidden":true}
        """.utf8)

        let item = try await client.confirmUpload(itemID: "i1", sensitive: true, in: "g1")

        #expect(item.isHidden)
        let body = try JSONSerialization.jsonObject(with: try #require(StubURLProtocol.requests.first?.httpBody)) as? [String: Any]
        #expect(body?["itemId"] as? String == "i1")
        #expect(body?["sensitive"] as? Bool == true)
    }
}
