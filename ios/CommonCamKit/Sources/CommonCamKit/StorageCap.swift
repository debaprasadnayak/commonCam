import Foundation

/// How full a group's storage is (SPEC.md section 8). Decided by the Worker (`storageCap.ts`) and sent as
/// `storageLevel`; the app never recomputes it from the bytes.
public enum StorageLevel: String, Codable, Sendable {
    case ok, nearlyFull, full
}

/// A group's storage usage, from `GET /groups/:id/storage` (any active member) or the host's group JSON.
public struct GroupStorage: Codable, Equatable, Sendable {
    public let usedBytes: Int64
    public let capBytes: Int64
    public let level: StorageLevel

    public init(usedBytes: Int64, capBytes: Int64, level: StorageLevel) {
        self.usedBytes = usedBytes
        self.capBytes = capBytes
        self.level = level
    }

    /// Share of the cap in use, 0…1 (for a progress bar).
    public var fractionUsed: Double { capBytes > 0 ? min(1, Double(usedBytes) / Double(capBytes)) : 1 }

    /// What the host and co-hosts are told when nearly full or full; nil otherwise.
    public var hostWarning: String? {
        switch level {
        case .ok:
            nil
        case .nearlyFull:
            "Storage is \(Int(fractionUsed * 100))% full. Upgrade or add storage so guests can keep sharing."
        case .full:
            "Storage is full. Uploads are paused: guests' shots wait on their phones for 24 hours "
                + "and send by themselves once you upgrade or add storage."
        }
    }

    enum CodingKeys: String, CodingKey {
        case usedBytes = "storageUsedBytes"
        case capBytes = "storageCapBytes"
        case level = "storageLevel"
    }
}

extension EventGroup {
    public var storage: GroupStorage { GroupStorage(usedBytes: storageUsedBytes, capBytes: storageCapBytes, level: storageLevel) }
}

extension APIClient {
    /// The group's storage usage; works for guests too, so their queue can tell when a full group has room again.
    public func storage(of groupID: String) async throws -> GroupStorage {
        try await send("GET", "groups/\(groupID)/storage")
    }
}

extension Collection<QueuedUpload> {
    /// Whether shots paused by a full group should be retried now that `storage` (freshly fetched) has room.
    public func shouldResume(in groupID: String, storage: GroupStorage) -> Bool {
        storage.level != .full && contains { $0.groupID == groupID && $0.isWaitingForStorage }
    }

    /// What the guest is told about shots held back by the group's full storage, or nil if there are none.
    /// Dropped shots (still queued after 24 hours) are reported first: that is the news the guest must not miss.
    public func storageNotice(in groupID: String) -> String? {
        let inGroup = filter { $0.groupID == groupID }
        let dropped = inGroup.filter { $0.failure == 413 }.count
        if dropped > 0 {
            let shots = dropped == 1 ? "1 shot wasn't shared" : "\(dropped) shots weren't shared"
            return "\(shots): the group's storage stayed full for 24 hours, so they were taken off the upload queue. "
                + "If saving to Photos is on, they're still in your library."
        }
        let waiting = inGroup.filter(\.isWaitingForStorage).count
        if waiting > 0 {
            let shots = waiting == 1 ? "1 shot is waiting" : "\(waiting) shots are waiting"
            return "The group's storage is full. \(shots) on your phone and will send by themselves "
                + "if the host adds space within 24 hours."
        }
        return nil
    }
}
