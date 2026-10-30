import Foundation

/// The device's Photos library, add-only. The app adapts PhotoKit to this so saving logic is testable without it.
public protocol PhotoLibrary: Sendable {
    /// Asks for (or reports existing) add-only access; false when the user has denied or restricted it.
    func requestAddAccess() async -> Bool
    /// Adds one encoded photo (HEIC/JPEG) as a new asset.
    func addPhoto(_ data: Data) async throws
    /// Adds one QuickTime clip as a new asset.
    func addVideo(_ data: Data) async throws
}

public struct BulkSaveProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// Outcome of saving gallery items. `failed` holds item ids that couldn't be downloaded or added.
public struct BulkSaveReport: Equatable, Sendable {
    public let saved: [String]
    public let failed: [String]
    /// Photos access was refused, so nothing was attempted.
    public let accessDenied: Bool

    public init(saved: [String], failed: [String], accessDenied: Bool) {
        self.saved = saved
        self.failed = failed
        self.accessDenied = accessDenied
    }
}

/// Saves photos to the device's own Photos library: shared-gallery items (one or many) and fresh captures. Photos
/// with a filter recipe are saved as their filtered version (the item detail view can still save the original),
/// except in a bulk save of originals (SPEC.md section 9.2).
public struct PhotoSaver: Sendable {
    private let library: PhotoLibrary
    private let download: @Sendable (URL) async throws -> Data

    /// `download` fetches a gallery item's bytes from its signed URL (no device token needed).
    public init(library: PhotoLibrary, download: @escaping @Sendable (URL) async throws -> Data) {
        self.library = library
        self.download = download
    }

    /// Saves items one at a time (keeps memory flat for big batches), carrying on past individual failures.
    /// With `originals`, photos are saved untouched (no filter render); videos are always saved as they are.
    public func save(
        _ items: [GalleryItem], originals: Bool = false, progress: @Sendable (BulkSaveProgress) async -> Void = { _ in }
    ) async -> BulkSaveReport {
        guard await library.requestAddAccess() else {
            return BulkSaveReport(saved: [], failed: items.map(\.id), accessDenied: true)
        }
        var saved: [String] = []
        var failed: [String] = []
        for (index, item) in items.enumerated() {
            do {
                let data = try await download(item.downloadUrl)
                if item.isVideo {
                    try await library.addVideo(data)
                } else {
                    try await library.addPhoto(originals ? data : Self.filtered(data, with: item.filterRecipe))
                }
                saved.append(item.id)
            } catch {
                failed.append(item.id)
            }
            await progress(BulkSaveProgress(done: index + 1, total: items.count))
        }
        return BulkSaveReport(saved: saved, failed: failed, accessDenied: false)
    }

    /// Saves a fresh capture to the contributor's own library. Purely local, so it never touches group storage.
    /// Never throws: a refused or failed save must not stop the photo being shared.
    public func autoSave(_ photo: CapturedPhoto, enabled: Bool) async -> AutoSaveOutcome {
        guard enabled else { return .off }
        guard await library.requestAddAccess() else { return .accessDenied }
        do {
            try await library.addPhoto(Self.filtered(photo.data, with: photo.filterRecipe))
            return .saved
        } catch {
            return .failed
        }
    }
}

extension PhotoSaver {
    /// The filtered render of `original`, or `original` itself when there is no recipe or this build can't render it
    /// (the gallery shows the original in that case too).
    static func filtered(_ original: Data, with recipe: FilterRecipe?) -> Data {
        guard let recipe else { return original }
        return (try? FilterRenderer.renderedJPEG(of: original, with: recipe)) ?? original
    }
}

public enum AutoSaveOutcome: Equatable, Sendable {
    case off, saved, accessDenied, failed
}

/// "Save my captures to Photos" preference. On unless the user turned it off.
public struct AutoSaveSetting {
    /// UserDefaults key; the app binds it with `@AppStorage(AutoSaveSetting.key)` defaulting to true.
    public static let key = "autoSaveToPhotos"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
