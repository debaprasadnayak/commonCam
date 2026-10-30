import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import CommonCamKit

/// Stands in for PhotoKit: records what was added and can refuse access or fail specific photos.
actor FakePhotoLibrary: PhotoLibrary {
    var granted: Bool
    var failing: Set<Data>
    private(set) var added: [Data] = []
    private(set) var addedVideos: [Data] = []
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

    func addVideo(_ data: Data) async throws {
        addedVideos.append(data)
    }
}

private struct DownloadFailed: Error {}

private func item(_ id: String, type: String = "photo") -> GalleryItem {
    GalleryItem(
        id: id, type: type, contentType: "image/jpeg", bytes: 3, createdAt: Date(timeIntervalSince1970: 0),
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

/// A small, fully red PNG: something `FilterRenderer` can decode, unlike the placeholder bytes above.
private let redPNG: Data = {
    let image = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
        .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    return FilterRenderer.context.pngRepresentation(
        of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )!
}()

/// The first pixel's sRGB channels, and whether the data is a JPEG.
private func firstPixel(of data: Data) throws -> (rgb: [Int], isJPEG: Bool) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var out = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (out.prefix(3).map(Int.init), CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
}

private func isGrey(_ rgb: [Int]) -> Bool {
    abs(rgb[0] - rgb[1]) <= 2 && abs(rgb[1] - rgb[2]) <= 2
}

struct FilteredSaveTests {
    private let ink = FilterRecipe(id: "ink", version: 1)

    private func photo(_ id: String, recipe: FilterRecipe?) -> GalleryItem {
        var photo = item(id)
        photo.filterRecipe = recipe
        return photo
    }

    @Test func savesTheFilteredVersionOfItemsThatHaveARecipeAndOriginalsOfThoseWithout() async throws {
        let library = FakePhotoLibrary()
        let saver = PhotoSaver(library: library, download: { _ in redPNG })

        let report = await saver.save([photo("a", recipe: ink), photo("b", recipe: nil)])

        #expect(report.saved == ["a", "b"])
        let added = await library.added
        try #require(added.count == 2)
        let filtered = try firstPixel(of: added[0])
        #expect(filtered.isJPEG && isGrey(filtered.rgb))
        #expect(added[1] == redPNG)
    }

    @Test func bulkSavesOriginalsIncludingVideos() async throws {
        let library = FakePhotoLibrary()
        let saver = PhotoSaver(library: library, download: { _ in redPNG })

        let report = await saver.save([photo("a", recipe: ink), item("v", type: "video")], originals: true)

        #expect(report.saved == ["a", "v"])
        #expect(await library.added == [redPNG])
        #expect(await library.addedVideos == [redPNG])
    }

    @Test func savesTheOriginalWhenThisBuildCannotRenderTheRecipe() async {
        let library = FakePhotoLibrary()
        let saver = PhotoSaver(library: library, download: { _ in redPNG })

        let report = await saver.save([photo("a", recipe: FilterRecipe(id: "from-the-future", version: 1))])

        #expect(report.saved == ["a"])
        #expect(await library.added == [redPNG])
    }

    @Test func autoSavesTheFilteredVersionOfACaptureWithARecipe() async throws {
        let library = FakePhotoLibrary()
        let saver = PhotoSaver(library: library, download: downloader())

        #expect(await saver.autoSave(CapturedPhoto(data: redPNG, format: .jpeg, filterRecipe: ink), enabled: true) == .saved)

        let added = await library.added
        try #require(added.count == 1)
        let filtered = try firstPixel(of: added[0])
        #expect(filtered.isJPEG && isGrey(filtered.rgb))
    }
}
