import Foundation

/// A started multipart upload: the original is sent as `partCount` parts of `partSize` bytes (the last may be shorter).
public struct MultipartUpload: Codable, Equatable, Sendable {
    public let itemId: String
    public let partSize: Int64
    public let partCount: Int
}

/// A signed URL to PUT one part to.
public struct PartURL: Codable, Equatable, Sendable {
    public let partNumber: Int
    public let url: URL
}

/// What the server already has (`uploadedParts`) and fresh URLs for the parts still missing.
public struct PartUploadPlan: Codable, Equatable, Sendable {
    public let uploadedParts: [Int]
    public let parts: [PartURL]
    public let expiresAt: Date
}

/// The server side of a resumable upload, as the upload queue needs it.
public protocol UploadService: Sendable {
    func startUpload(bytes: Int64, contentType: String, in groupID: String) async throws -> MultipartUpload
    func partPlan(itemID: String, in groupID: String) async throws -> PartUploadPlan
    func completeUpload(itemID: String, in groupID: String) async throws
    func confirmUpload(itemID: String, filterRecipe: FilterRecipe?, in groupID: String) async throws -> GalleryItem
}

extension APIClient: UploadService {
    /// Checks the group is open, we are the host or an active member, and the original fits the storage cap.
    public func startUpload(bytes: Int64, contentType: String, in groupID: String) async throws -> MultipartUpload {
        let body: [String: any Sendable] = ["bytes": bytes, "contentType": contentType]
        return try await send("POST", "groups/\(groupID)/multipart", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// Safe to call any number of times, e.g. after a relaunch or when the part URLs have expired.
    public func partPlan(itemID: String, in groupID: String) async throws -> PartUploadPlan {
        try await send("POST", "groups/\(groupID)/multipart/\(itemID)/parts")
    }

    public func completeUpload(itemID: String, in groupID: String) async throws {
        _ = try await sendForData("POST", "groups/\(groupID)/multipart/\(itemID)/complete")
    }

    /// Makes the item visible in the gallery and stores the shot's filter recipe (the first confirm wins).
    public func confirmUpload(itemID: String, filterRecipe: FilterRecipe? = nil, in groupID: String) async throws -> GalleryItem {
        try await send("POST", "groups/\(groupID)/items", body: try JSONEncoder().encode(Confirm(itemId: itemID, filterRecipe: filterRecipe)))
    }

    private struct Confirm: Encodable {
        let itemId: String
        let filterRecipe: FilterRecipe?
    }
}
