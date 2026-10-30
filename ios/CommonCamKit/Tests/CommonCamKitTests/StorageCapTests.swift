import Foundation
import Testing
@testable import CommonCamKit

struct StorageCapTests {
    @Test func theHostIsWarnedWhenNearlyFullAndToldUploadsPauseWhenFull() throws {
        #expect(GroupStorage(usedBytes: 50, capBytes: 100, level: .ok).hostWarning == nil)

        let nearlyFull = try #require(GroupStorage(usedBytes: 857, capBytes: 1000, level: .nearlyFull).hostWarning)
        #expect(nearlyFull.contains("85% full"))

        let full = try #require(GroupStorage(usedBytes: 1000, capBytes: 1000, level: .full).hostWarning)
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

        #expect(!queue.shouldResume(in: "g1", storage: GroupStorage(usedBytes: 100, capBytes: 200, level: .full)))
        #expect(queue.shouldResume(in: "g1", storage: GroupStorage(usedBytes: 100, capBytes: 100, level: .nearlyFull)))
        #expect(!queue.shouldResume(in: "g2", storage: GroupStorage(usedBytes: 100, capBytes: 200, level: .ok)))
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
    @Test func aGroupsStorageLevelComesFromTheAPI() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"""
        [{"id":"g1","tier":"taster","state":"Active","peopleCap":4,"storageCapBytes":1000,"storageUsedBytes":10,
          "storageLevel":"full","startsAt":"2026-10-30T08:00:00.000Z","endsAt":"2026-10-31T08:00:00.000Z"}]
        """#.utf8)

        let group = try #require(try await client.myGroups().first)

        // The Worker decides the level; the app never recomputes it from the bytes.
        #expect(group.storage == GroupStorage(usedBytes: 10, capBytes: 1000, level: .full))
    }

    @Test func fetchesAGroupsStorageForGuests() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data(#"{"storageUsedBytes":1000,"storageCapBytes":1000,"storageLevel":"full"}"#.utf8)

        let storage = try await client.storage(of: "g1")

        #expect(storage == GroupStorage(usedBytes: 1000, capBytes: 1000, level: .full))
        #expect(StubURLProtocol.requests.first?.url?.absoluteString == "https://api.test/groups/g1/storage")
    }
}
