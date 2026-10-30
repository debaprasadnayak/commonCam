import Foundation
import Testing
@testable import CommonCamKit

/// Stands in for PhotoKit: records what was added and can refuse access or fail specific photos.
actor FakePhotoLibrary: PhotoLibrary {
    var granted: Bool
    var failing: Set<Data>
    private(set) var added: [Data] = []
    private(set) var accessRequests = 0

    init(granted: Bool = true, failing: Set<Data> = []) {
        self.granted = granted
        self.failing = failing
    }

    func requestAddAccess() async -> Bool {
        accessRequests += 1
        return granted
    }

    func addPhoto(_ data: Data) async throws {
        if failing.contains(data) { throw URLError(.cannotWriteToFile) }
        added.append(data)
    }
}

private struct DownloadFailed: Error {}

private func item(_ id: String) -> GalleryItem {
    GalleryItem(
        id: id, type: "photo", contentType: "image/jpeg", bytes: 3, createdAt: Date(timeIntervalSince1970: 0),
        contributor: Contributor(memberId: nil, displayName: "Host", colour: "#8E8E93"),
        downloadUrl: URL(string: "https://example.test/media/\(id)")!, downloadUrlExpiresAt: Date(timeIntervalSince1970: 900))
}

/// Serves each item's URL as its id's bytes, except ids listed in `broken`.
private func downloader(broken: Set<String> = []) -> @Sendable (URL) async throws -> Data {
    { url in
        if broken.contains(url.lastPathComponent) { throw DownloadFailed() }
        return Data(url.lastPathComponent.utf8)
    }
}

private actor ProgressLog {
    var updates: [BulkSaveProgress] = []
    func record(_ progress: BulkSaveProgress) { updates.append(progress) }
}

struct BulkSaveTests {
    @Test func savesEveryOriginalAndReportsProgressAfterEachItem() async {
        let library = FakePhotoLibrary()
        let saver = PhotoSaver(library: library, download: downloader())
        let log = ProgressLog()

        let report = await saver.save([item("a"), item("b"), item("c")]) { await log.record($0) }

        #expect(await library.added == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        #expect(report == BulkSaveReport(saved: ["a", "b", "c"], failed: [], accessDenied: false))
        #expect(await log.updates == [
            BulkSaveProgress(done: 1, total: 3), BulkSaveProgress(done: 2, total: 3), BulkSaveProgress(done: 3, total: 3),
        ])
    }

    @Test func carriesOnPastFailedDownloadsAndRefusedPhotosAndReportsThem() async {
        let library = FakePhotoLibrary(failing: [Data("c".utf8)])
        let saver = PhotoSaver(library: library, download: downloader(broken: ["b"]))
        let log = ProgressLog()

        let report = await saver.save([item("a"), item("b"), item("c"), item("d")]) { await log.record($0) }

        #expect(report == BulkSaveReport(saved: ["a", "d"], failed: ["b", "c"], accessDenied: false))
        #expect(await log.updates.last == BulkSaveProgress(done: 4, total: 4))
    }

    @Test func savesNothingAndSaysSoWhenPhotosAccessIsDenied() async {
        let library = FakePhotoLibrary(granted: false)
        let saver = PhotoSaver(library: library, download: { _ in Issue.record("must not download"); return Data() })

        let report = await saver.save([item("a"), item("b")])

        #expect(report == BulkSaveReport(saved: [], failed: ["a", "b"], accessDenied: true))
        #expect(await library.added.isEmpty)
    }
}

struct AutoSaveTests {
    private let photo = CapturedPhoto(data: Data("shot".utf8), format: .heic)

    @Test func isOnByDefaultAndRemembersWhenTurnedOff() {
        let defaults = UserDefaults(suiteName: "AutoSaveTests-\(UUID().uuidString)")!
        #expect(AutoSaveSetting(defaults: defaults).isEnabled)

        let setting = AutoSaveSetting(defaults: defaults)
        setting.isEnabled = false
        #expect(AutoSaveSetting(defaults: defaults).isEnabled == false)
    }

    @Test func savesTheCapturedOriginalWhenOn() async {
        let library = FakePhotoLibrary()
        let saver = PhotoSaver(library: library, download: downloader())

        #expect(await saver.autoSave(photo, enabled: true) == .saved)
        #expect(await library.added == [Data("shot".utf8)])
    }

    @Test func leavesPhotosAloneWhenOff() async {
        let library = FakePhotoLibrary()
        let saver = PhotoSaver(library: library, download: downloader())

        #expect(await saver.autoSave(photo, enabled: false) == .off)
        #expect(await library.added.isEmpty)
        #expect(await library.accessRequests == 0)
    }

    @Test func reportsDenialAndFailureWithoutThrowing() async {
        let denied = PhotoSaver(library: FakePhotoLibrary(granted: false), download: downloader())
        #expect(await denied.autoSave(photo, enabled: true) == .accessDenied)

        let broken = PhotoSaver(library: FakePhotoLibrary(failing: [Data("shot".utf8)]), download: downloader())
        #expect(await broken.autoSave(photo, enabled: true) == .failed)
    }
}
