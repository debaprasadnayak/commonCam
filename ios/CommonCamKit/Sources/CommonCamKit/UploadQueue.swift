import Foundation

/// Sends one part file to a signed URL. Implementations should keep going while the app is suspended or killed
/// (see `BackgroundUploadTransport`); `taskID` names the part across launches so it is not sent twice.
public protocol PartTransport: Sendable {
    func upload(file: URL, to url: URL, taskID: String) async throws
}

/// A captured original waiting to be shared. Pending until the server has confirmed it into the gallery.
public struct QueuedUpload: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let groupID: String
    public let contentType: String
    public let bytes: Int64
    public let createdAt: Date
    let fileExtension: String
    /// The look chosen at capture; sent with the confirm so the gallery can render it. Absent in queues saved before filters.
    public let filterRecipe: FilterRecipe?
    /// Set once the server has accepted the upload; parts then go to this item.
    public internal(set) var itemID: String?
    public internal(set) var partCount: Int?
    var partSize: Int64?
    /// Parts the server is known to have stored.
    public internal(set) var uploadedParts: Set<Int> = []
    var isAssembled = false
    /// The on-device sensitive-content verdict, taken once before the first confirm and kept across relaunches.
    var flaggedSensitive: Bool?
    /// HTTP status that made the server refuse this shot for good; it is no longer retried.
    public internal(set) var failure: Int?

    /// Still on its way to the gallery (the "pending" badge).
    public var isPending: Bool { failure == nil }
}

/// The persisted, resumable queue of shots to share.
///
/// Each original is written to `directory` before anything is sent, and the queue state is saved after every step,
/// so app termination, a device restart or going offline never loses a shot: `run()` picks up where it left off,
/// asking the server which parts it already has and sending only the rest.
public actor UploadQueue {
    /// SPEC: when the group's storage is full, shots stay queued on the phone this long before giving up.
    public static let storageFullGracePeriod: TimeInterval = 24 * 60 * 60

    private let directory: URL
    private let service: UploadService
    private let transport: PartTransport
    private let analyzer: SensitiveContentAnalyzer?
    private let now: @Sendable () -> Date
    public private(set) var uploads: [QueuedUpload]
    private var isRunning = false
    private var observer: (@Sendable ([QueuedUpload]) -> Void)?

    /// `analyzer`: checks each shot for likely explicit content before it is confirmed; nil = no check.
    public init(
        directory: URL, service: UploadService, transport: PartTransport, analyzer: SensitiveContentAnalyzer? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.directory = directory
        self.service = service
        self.transport = transport
        self.analyzer = analyzer
        self.now = now
        let saved = try? Data(contentsOf: directory.appending(path: "queue.json"))
        uploads = saved.flatMap { try? Self.decoder.decode([QueuedUpload].self, from: $0) } ?? []
    }

    /// Called with the current queue whenever it changes.
    public func observe(_ observer: @escaping @Sendable ([QueuedUpload]) -> Void) {
        self.observer = observer
        observer(uploads)
    }

    public func uploads(in groupID: String) -> [QueuedUpload] {
        uploads.filter { $0.groupID == groupID }
    }

    /// The original as captured, e.g. to show a thumbnail while it is pending.
    public nonisolated func originalFile(of upload: QueuedUpload) -> URL {
        directory.appending(path: "\(upload.id.uuidString).\(upload.fileExtension)")
    }

    @discardableResult
    public func enqueue(_ photo: CapturedPhoto, in groupID: String) throws -> QueuedUpload {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let upload = QueuedUpload(
            id: UUID(), groupID: groupID, contentType: photo.format.contentType, bytes: Int64(photo.data.count),
            createdAt: now(), fileExtension: photo.format.rawValue, filterRecipe: photo.filterRecipe
        )
        try photo.data.write(to: originalFile(of: upload), options: .atomic)
        uploads.append(upload)
        try save()
        return upload
    }

    /// Queues a recorded clip. The file is moved (not copied) into the queue and later sent part by part from disk.
    @discardableResult
    public func enqueue(_ video: CapturedVideo, in groupID: String) throws -> QueuedUpload {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try FileManager.default.attributesOfItem(atPath: video.file.path())[.size] as? Int64 ?? 0
        let upload = QueuedUpload(
            id: UUID(), groupID: groupID, contentType: CapturedVideo.contentType, bytes: bytes,
            createdAt: now(), fileExtension: CapturedVideo.fileExtension, filterRecipe: nil
        )
        try FileManager.default.moveItem(at: video.file, to: originalFile(of: upload))
        uploads.append(upload)
        try save()
        return upload
    }

    /// Forgets a shot (e.g. one the server refused) and deletes its files.
    public func remove(_ id: UUID) {
        guard let upload = uploads.first(where: { $0.id == id }) else { return }
        uploads.removeAll { $0.id == id }
        deleteFiles(of: upload)
        try? save()
    }

    /// Pushes every pending shot as far as it gets and returns the ones confirmed into the gallery.
    /// A shot that hits a network error stays queued for the next run; overlapping calls return immediately.
    @discardableResult
    public func run() async -> [GalleryItem] {
        guard !isRunning else { return [] }
        isRunning = true
        defer { isRunning = false }
        var confirmed: [GalleryItem] = []
        for id in uploads.filter(\.isPending).map(\.id) {
            do {
                if let item = try await advance(id) { confirmed.append(item) }
            } catch let error as APIError where Self.isPermanent(error) {
                _ = try? update(id) { $0.failure = error.statusCode }
            } catch let error as APIError where error.statusCode == 413 {
                if let upload = uploads.first(where: { $0.id == id }),
                   now().timeIntervalSince(upload.createdAt) > Self.storageFullGracePeriod {
                    _ = try? update(id) { $0.failure = 413 }
                }
            } catch {
                // Offline, timed out, server hiccup: retried on the next run.
            }
        }
        return confirmed
    }

    private func advance(_ id: UUID) async throws -> GalleryItem? {
        guard var upload = uploads.first(where: { $0.id == id }) else { return nil }
        if upload.itemID == nil {
            let started = try await service.startUpload(bytes: upload.bytes, contentType: upload.contentType, in: upload.groupID)
            upload = try update(id) {
                $0.itemID = started.itemId
                $0.partSize = started.partSize
                $0.partCount = started.partCount
            }
        }
        guard let itemID = upload.itemID else { return nil }

        if !upload.isAssembled {
            let plan = try await service.partPlan(itemID: itemID, in: upload.groupID)
            upload = try update(id) { $0.uploadedParts = Set(plan.uploadedParts) }
            for part in plan.parts.sorted(by: { $0.partNumber < $1.partNumber }) {
                let file = try partFile(part.partNumber, of: upload)
                try await transport.upload(file: file, to: part.url, taskID: "\(id.uuidString)#\(part.partNumber)")
                if file != originalFile(of: upload) { try? FileManager.default.removeItem(at: file) }
                upload = try update(id) { $0.uploadedParts.insert(part.partNumber) }
            }
            try await service.completeUpload(itemID: itemID, in: upload.groupID)
            upload = try update(id) { $0.isAssembled = true }
        }

        if upload.flaggedSensitive == nil {
            // The analyzer only understands still images; clips are confirmed unflagged.
            let flagged = if upload.isVideo { false } else { await analyzer?.shouldFlag(imageAt: originalFile(of: upload)) ?? false }
            upload = try update(id) { $0.flaggedSensitive = flagged }
        }
        let item = try await service.confirmUpload(
            itemID: itemID, filterRecipe: upload.filterRecipe, sensitive: upload.flaggedSensitive == true, in: upload.groupID
        )
        remove(id)
        return item
    }

    /// Background URLSession uploads only from files, so each part is cut from the original into its own file.
    /// A single-part upload sends the original as is.
    private func partFile(_ partNumber: Int, of upload: QueuedUpload) throws -> URL {
        let original = originalFile(of: upload)
        guard let partSize = upload.partSize, let partCount = upload.partCount, partCount > 1 else { return original }
        let file = directory.appending(path: "\(upload.id.uuidString).part\(partNumber)")
        let handle = try FileHandle(forReadingFrom: original)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(Int64(partNumber - 1) * partSize))
        let data = try handle.read(upToCount: Int(partSize)) ?? Data()
        try data.write(to: file, options: .atomic)
        return file
    }

    private func deleteFiles(of upload: QueuedUpload) {
        let prefix = upload.id.uuidString
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Thrown when a shot is removed while it is being sent.
    private struct Removed: Error {}

    @discardableResult
    private func update(_ id: UUID, _ change: (inout QueuedUpload) -> Void) throws -> QueuedUpload {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { throw Removed() }
        change(&uploads[index])
        try? save()
        return uploads[index]
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(uploads).write(to: directory.appending(path: "queue.json"), options: .atomic)
        observer?(uploads)
    }

    /// The server will never accept these: bad request, not (or no longer) a member, group ended.
    private static func isPermanent(_ error: APIError) -> Bool {
        [400, 403, 404, 410].contains(error.statusCode)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
