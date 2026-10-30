import Foundation

/// The encoding a capture is stored in. Originals are uploaded exactly as captured.
public enum PhotoFormat: String, Sendable {
    case heic
    case jpeg

    public var contentType: String {
        switch self {
        case .heic: "image/heic"
        case .jpeg: "image/jpeg"
        }
    }

    /// Full-resolution HEIC when the camera can encode HEVC, else JPEG; nil when there is no camera.
    /// `availableCodecs` are `AVVideoCodecType` raw values ("hvc1", "jpeg").
    public static func preferred(availableCodecs: [String]) -> PhotoFormat? {
        if availableCodecs.contains("hvc1") { return .heic }
        if availableCodecs.contains("jpeg") { return .jpeg }
        return nil
    }
}

/// The encoded original straight off the camera.
public struct CapturedPhoto: Sendable {
    public let data: Data
    public let format: PhotoFormat

    public init(data: Data, format: PhotoFormat) {
        self.data = data
        self.format = format
    }
}

/// A short-lived URL to upload one original to, for an item that is confirmed afterwards.
public struct UploadTicket: Codable, Equatable, Sendable {
    public let itemId: String
    public let uploadUrl: URL
    public let expiresAt: Date
}

/// Who shot an item. `memberId` is nil for the host.
public struct Contributor: Codable, Equatable, Hashable, Sendable {
    public let memberId: String?
    public let displayName: String
    public let colour: String
}

/// A confirmed photo in the shared gallery. `downloadUrl` expires at `downloadUrlExpiresAt`; re-list to refresh.
public struct GalleryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let type: String
    public let contentType: String
    public let bytes: Int64
    public let createdAt: Date
    public let contributor: Contributor
    public let downloadUrl: URL
    public let downloadUrlExpiresAt: Date
}
