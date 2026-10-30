import Foundation
import Testing
@testable import CommonCamKit

/// Stands in for the Worker: stores parts per item and only completes once every part arrived.
actor FakeServer: UploadService {
    let partSize: Int64
    var starts = 0
    var refuse: APIError?
    private var uploads: [String: (bytes: Int64, parts: [Int: Data], completed: Bool)] = [:]
    private(set) var stored: [String: Data] = [:]

    init(partSize: Int64) { self.partSize = partSize }

    func refuseEverything(with error: APIError?) { refuse = error }

    func startUpload(bytes: Int64, contentType: String, in groupID: String) async throws -> MultipartUpload {
        if let refuse { throw refuse }
        starts += 1
        let itemID = "item-\(starts)"
        uploads[itemID] = (bytes, [:], false)
        let partCount = Int((bytes + partSize - 1) / partSize)
        return MultipartUpload(itemId: itemID, partSize: partSize, partCount: partCount)
    }

    func partPlan(itemID: String, in groupID: String) async throws -> PartUploadPlan {
        if let refuse { throw refuse }
        let upload = try #require(uploads[itemID])
        let partCount = Int((upload.bytes + partSize - 1) / partSize)
        let missing = (1...partCount).filter { upload.parts[$0] == nil }
        return PartUploadPlan(
            uploadedParts: upload.parts.keys.sorted(),
            parts: missing.map { PartURL(partNumber: $0, url: URL(string: "https://parts.test/\(itemID)/\($0)")!) },
            expiresAt: .distantFuture
        )
    }

    func receive(_ data: Data, at url: URL) {
        let itemID = url.pathComponents[1]
        uploads[itemID]!.parts[Int(url.lastPathComponent)!] = data
    }

    func completeUpload(itemID: String, in groupID: String) async throws {
        let upload = try #require(uploads[itemID])
        let partCount = Int((upload.bytes + partSize - 1) / partSize)
        guard upload.parts.count == partCount else { throw APIError(statusCode: 409) }
        stored[itemID] = upload.parts.keys.sorted().reduce(into: Data()) { $0.append(upload.parts[$1]!) }
        uploads[itemID]!.completed = true
    }

    func confirmUpload(itemID: String, in groupID: String) async throws -> GalleryItem {
        let data = try #require(stored[itemID])
        return GalleryItem(
            id: itemID, type: "photo", contentType: "image/heic", bytes: Int64(data.count), createdAt: .now,
            contributor: Contributor(memberId: nil, displayName: "Host", colour: "#8E8E93"),
            downloadUrl: URL(string: "https://api.test/media/\(itemID)")!, downloadUrlExpiresAt: .distantFuture
        )
    }
}

/// Delivers part files to the fake server, or drops the connection for the parts listed in `failing`.
final class FakeTransport: PartTransport, @unchecked Sendable {
    let server: FakeServer
    var failing: Set<Int> = []
    var sentParts: [Int] = []

    init(server: FakeServer) { self.server = server }

    func upload(file: URL, to url: URL, taskID: String) async throws {
        let part = Int(url.lastPathComponent)!
        sentParts.append(part)
        if failing.contains(part) { throw URLError(.networkConnectionLost) }
        await server.receive(try Data(contentsOf: file), at: url)
    }
}

private func photo(_ size: Int) -> CapturedPhoto {
    CapturedPhoto(data: Data((0..<size).map { UInt8(($0 * 31 + 7) % 256) }), format: .heic)
}

private func emptyDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "UploadQueueTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct UploadQueueTests {
    let directory: URL
    let server = FakeServer(partSize: 10)
    let transport: FakeTransport

    init() throws {
        directory = try emptyDirectory()
        transport = FakeTransport(server: server)
    }

    private func makeQueue(now: @escaping @Sendable () -> Date = { .now }) -> UploadQueue {
        UploadQueue(directory: directory, service: server, transport: transport, now: now)
    }

    @Test func aQueuedShotSurvivesTheAppBeingKilled() async throws {
        let queued = try await makeQueue().enqueue(photo(25), in: "g1")

        let relaunched = makeQueue()

        #expect(await relaunched.uploads == [queued])
        #expect(await relaunched.uploads(in: "g1").first?.isPending == true)
        #expect(try Data(contentsOf: relaunched.originalFile(of: queued)) == photo(25).data)
    }

    @Test func uploadsEveryPartThenConfirmsAndForgetsTheShot() async throws {
        let queue = makeQueue()
        _ = try await queue.enqueue(photo(25), in: "g1")

        let confirmed = await queue.run()

        #expect(confirmed.map(\.id) == ["item-1"])
        #expect(await server.stored["item-1"] == photo(25).data)
        #expect(await queue.uploads.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path()).filter { $0 != "queue.json" }.isEmpty)
    }

    @Test func anInterruptedUploadResumesFromTheLastCompletedPartAfterRelaunch() async throws {
        _ = try await makeQueue().enqueue(photo(25), in: "g1")
        transport.failing = [2]
        let first = makeQueue()
        #expect(await first.run().isEmpty)
        #expect(await first.uploads.first?.uploadedParts == [1])
        #expect(await first.uploads.first?.itemID == "item-1")

        transport.failing = []
        transport.sentParts = []
        let relaunched = makeQueue()
        #expect(await relaunched.uploads.first?.uploadedParts == [1])
        let confirmed = await relaunched.run()

        #expect(confirmed.map(\.id) == ["item-1"])
        #expect(transport.sentParts == [2, 3])
        #expect(await server.starts == 1)
        #expect(await server.stored["item-1"] == photo(25).data)
    }

    @Test func partsThatFinishedInTheBackgroundWhileTheAppWasDeadAreNotResent() async throws {
        let queue = makeQueue()
        _ = try await queue.enqueue(photo(25), in: "g1")
        transport.failing = [1, 2, 3]
        await queue.run()
        // The background session finished part 2 after the app was killed, so only the server knows.
        await server.receive(photo(25).data[10..<20], at: URL(string: "https://parts.test/item-1/2")!)

        transport.failing = []
        transport.sentParts = []
        await makeQueue().run()

        #expect(transport.sentParts == [1, 3])
        #expect(await server.stored["item-1"] == photo(25).data)
    }

    @Test func aGroupThatEndedStopsRetryingAndKeepsTheShotMarkedFailed() async throws {
        let queue = makeQueue()
        _ = try await queue.enqueue(photo(5), in: "g1")
        await server.refuseEverything(with: APIError(statusCode: 410))

        await queue.run()
        await queue.run()

        #expect(await server.starts == 0)
        let upload = try #require(await makeQueue().uploads.first)
        #expect(upload.failure == 410)
        #expect(!upload.isPending)
    }

    @Test func fullStorageKeepsTheShotQueuedFor24Hours() async throws {
        let start = Date.now
        _ = try await makeQueue(now: { start }).enqueue(photo(5), in: "g1")
        await server.refuseEverything(with: APIError(statusCode: 413))

        await makeQueue(now: { start.addingTimeInterval(23 * 3600) }).run()
        #expect(await makeQueue().uploads.first?.failure == nil)

        await makeQueue(now: { start.addingTimeInterval(25 * 3600) }).run()
        #expect(await makeQueue().uploads.first?.failure == 413)
    }

    @Test func aRemovedShotIsForgottenWithItsFiles() async throws {
        let queue = makeQueue()
        let queued = try await queue.enqueue(photo(5), in: "g1")

        await queue.remove(queued.id)

        #expect(await makeQueue().uploads.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: queue.originalFile(of: queued).path()))
    }
}
