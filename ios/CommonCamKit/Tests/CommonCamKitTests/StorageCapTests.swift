import Foundation
import Testing
@testable import CommonCamKit

private let gigabyte: Int64 = 1024 * 1024 * 1024

struct StorageCapTests {
    @Test func levelWarnsFrom80PercentAndIsFullFrom100() {
        #expect(StorageLevel(usedBytes: 0, capBytes: 100) == .ok)
        #expect(StorageLevel(usedBytes: 79, capBytes: 100) == .ok)
        #expect(StorageLevel(usedBytes: 80, capBytes: 100) == .nearlyFull)
        #expect(StorageLevel(usedBytes: 99, capBytes: 100) == .nearlyFull)
        #expect(StorageLevel(usedBytes: 100, capBytes: 100) == .full)
        #expect(StorageLevel(usedBytes: 130, capBytes: 100) == .full)
        #expect(StorageLevel(usedBytes: 0, capBytes: 0) == .full)
    }

    @Test func aGroupKnowsItsLevelFromItsUsageAndCap() {
        let group = EventGroup(
            id: "g1", tier: "taster", state: "Active", peopleCap: 4, storageCapBytes: gigabyte,
            storageUsedBytes: gigabyte * 9 / 10, startsAt: .now, endsAt: .now
        )

        #expect(group.storage == GroupStorage(usedBytes: gigabyte * 9 / 10, capBytes: gigabyte))
        #expect(group.storage.level == .nearlyFull)
    }

    @Test func theHostIsWarnedAt80PercentAndToldUploadsPauseAt100() throws {
        #expect(GroupStorage(usedBytes: 50, capBytes: 100).hostWarning == nil)

        let nearlyFull = try #require(GroupStorage(usedBytes: 857, capBytes: 1000).hostWarning)
        #expect(nearlyFull.contains("85% full"))

        let full = try #require(GroupStorage(usedBytes: 1000, capBytes: 1000).hostWarning)
        #expect(full.contains("Uploads are paused"))
        #expect(full.contains("24 hours"))
    }
}

struct StorageQueueStateTests {
    private func upload(group: String = "g1", storageFullSince: Date? = nil, failure: Int? = nil) -> QueuedUpload {
        var upload = QueuedUpload(
            id: UUID(), groupID: group, contentType: "image/heic", bytes: 5, createdAt: .now, fileExtension: "heic", filterRecipe: nil
        )
        upload.storageFullSince = storageFullSince
        upload.failure = failure
        return upload
    }

    @Test func queuedShotsResumeOnlyOnceTheirGroupHasRoomAgain() {
        let queue = [upload(storageFullSince: .now), upload(group: "g2")]

        #expect(!queue.shouldResume(in: "g1", storage: GroupStorage(usedBytes: 100, capBytes: 100)))
        #expect(queue.shouldResume(in: "g1", storage: GroupStorage(usedBytes: 100, capBytes: 200)))
        #expect(!queue.shouldResume(in: "g2", storage: GroupStorage(usedBytes: 100, capBytes: 200)))
    }

    @Test func theGuestIsToldShotsAreWaitingForSpace() throws {
        let queue = [upload(storageFullSince: .now), upload(storageFullSince: .now), upload(group: "g2", storageFullSince: .now)]

        let notice = try #require(queue.storageNotice(in: "g1"))

        #expect(notice.contains("2 shots are waiting"))
        #expect([upload()].storageNotice(in: "g1") == nil)
    }

    @Test func theGuestIsToldClearlyWhenShotsWereDroppedAfter24Hours() throws {
        let queue = [upload(storageFullSince: .now), upload(failure: 413)]

        let notice = try #require(queue.storageNotice(in: "g1"))

        #expect(notice.contains("1 shot wasn't shared"))
        #expect(notice.contains("full for 24 hours"))
    }
}

extension APIClientTests {
    @Test func fetchesAGroupsStorageForGuests() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"storageUsedBytes":1000,"storageCapBytes":1000,"storageLevel":"full"}"#.utf8)

        let storage = try await client.storage(of: "g1")

        #expect(storage == GroupStorage(usedBytes: 1000, capBytes: 1000))
        #expect(storage.level == .full)
        #expect(StubURLProtocol.requests.first?.url?.absoluteString == "https://api.test/groups/g1/storage")
    }
}
