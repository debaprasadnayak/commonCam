import Foundation
import Testing
@testable import CommonCamKit

struct ClipRecordingTests {
    @Test func recordsFramesUntilSixtySecondsAfterTheFirstThenStops() {
        var clip = ClipRecording()

        #expect(clip.frame(at: 1000) == .record)
        #expect(clip.frame(at: 1030) == .record)
        #expect(clip.frame(at: 1059.98) == .record)
        #expect(clip.frame(at: 1060) == .stop)
    }

    @Test func onceStoppedLaterFramesAreRefusedToo() {
        var clip = ClipRecording()
        _ = clip.frame(at: 5)
        _ = clip.frame(at: 65)

        #expect(clip.frame(at: 66) == .stop)
        #expect(clip.isFinished)
    }

    @Test func stoppingByHandEndsTheClipEarly() {
        var clip = ClipRecording()
        _ = clip.frame(at: 0)

        clip.stop()

        #expect(clip.frame(at: 1) == .stop)
    }

    @Test func soundIsKeptOnlyWithinTheRecordedPictures() {
        var clip = ClipRecording()
        #expect(!clip.acceptsAudio(at: 9), "no sound before the first frame starts the clip")
        _ = clip.frame(at: 10)

        #expect(!clip.acceptsAudio(at: 9.5))
        #expect(clip.acceptsAudio(at: 10))
        #expect(clip.acceptsAudio(at: 69.9))
        #expect(!clip.acceptsAudio(at: 70))
    }

    @Test func countsDownTheTimeLeft() {
        var clip = ClipRecording()
        #expect(clip.remaining(at: 3) == 60)
        _ = clip.frame(at: 3)

        #expect(clip.remaining(at: 3) == 60)
        #expect(abs(clip.remaining(at: 48.2) - 14.8) < 0.000_001)
        #expect(clip.remaining(at: 100) == 0)
        #expect(ClipRecording.countdownLabel(remaining: 60) == "1:00")
        #expect(ClipRecording.countdownLabel(remaining: 14.8) == "0:15")
        #expect(ClipRecording.countdownLabel(remaining: 0) == "0:00")
    }
}

struct VideoUploadTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "VideoUploadTests-\(UUID().uuidString)")
    let server = FakeServer(partSize: 10)

    /// A finished recording in the camera's scratch space, as `Camera` hands it over.
    private func recordedClip(_ size: Int) throws -> (CapturedVideo, Data) {
        let bytes = Data((0..<size).map { UInt8(($0 * 17 + 3) % 256) })
        let file = FileManager.default.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).mov")
        try bytes.write(to: file)
        return (CapturedVideo(file: file), bytes)
    }

    @Test func aClipIsMovedIntoTheQueueAndSentInPartsAsAVideoWithoutARecipe() async throws {
        let queue = UploadQueue(directory: directory, service: server, transport: FakeTransport(server: server))
        let (clip, bytes) = try recordedClip(25)

        let queued = try await queue.enqueue(clip, in: "g1")

        #expect(queued.isVideo)
        #expect(queued.contentType == "video/quicktime")
        #expect(queued.bytes == 25)
        #expect(queued.filterRecipe == nil)
        #expect(!FileManager.default.fileExists(atPath: clip.file.path()), "moved, not copied: clips are large")
        #expect(try Data(contentsOf: queue.originalFile(of: queued)) == bytes)
        #expect(queue.originalFile(of: queued).pathExtension == "mov")

        let confirmed = await queue.run()

        #expect(confirmed.map(\.id) == ["item-1"])
        #expect(await server.contentTypes["item-1"] == "video/quicktime")
        #expect(await server.stored["item-1"] == bytes)
        #expect(await server.confirmedRecipes["item-1"] == .some(nil))
    }

    @Test func aQueuedClipSurvivesTheAppBeingKilled() async throws {
        let (clip, _) = try recordedClip(5)
        let queued = try await UploadQueue(directory: directory, service: server, transport: FakeTransport(server: server))
            .enqueue(clip, in: "g1")

        let relaunched = UploadQueue(directory: directory, service: server, transport: FakeTransport(server: server))

        #expect(await relaunched.uploads == [queued])
        #expect(await relaunched.uploads.first?.isVideo == true)
    }

    @Test func galleryItemsTellVideosFromPhotos() {
        func item(_ type: String) -> GalleryItem {
            GalleryItem(
                id: type, type: type, contentType: "", bytes: 1, createdAt: .now,
                contributor: Contributor(memberId: nil, displayName: "Host", colour: "#8E8E93"),
                downloadUrl: URL(string: "https://api.test/media/\(type)")!, downloadUrlExpiresAt: .distantFuture
            )
        }

        #expect([item("video"), item("photo")].map(\.isVideo) == [true, false])
    }
}
