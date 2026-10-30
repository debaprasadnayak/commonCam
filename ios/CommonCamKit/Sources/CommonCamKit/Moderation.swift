import Foundation

/// Where to send takedown requests. Shown in-app wherever content can be reported.
public enum Contact {
    // shortcut: placeholder address until Legal publishes the real takedown contact.
    public static let takedownEmail = "takedown@commoncam.example"

    public static var takedownMailURL: URL { URL(string: "mailto:\(takedownEmail)")! }
}

/// A report on an item or a member. Reported items stay hidden from guests until a host or co-host reviews them.
public struct Report: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let itemId: String?
    public let memberId: String?
    public let reason: String
    /// "open", then "restored" or "deleted" once reviewed.
    public let status: String
    public let createdAt: Date
    /// The reported item or member; only filled in the host's review list.
    public var item: GalleryItem? = nil
    public var member: Member? = nil

    public var isOpen: Bool { status == "open" }
}

/// How a host or co-host settles a report. Restore unhides the item (or dismisses a member report); delete removes the item.
public enum ReportDecision: String, CaseIterable, Sendable {
    case restore
    case delete
}

/// Report and block, available to every active member; review is for the host and co-hosts.
extension APIClient {
    public func reportItem(_ itemID: String, in groupID: String, reason: String) async throws -> Report {
        try await send("POST", "groups/\(groupID)/items/\(itemID)/report", body: try JSONEncoder().encode(["reason": reason]))
    }

    public func reportMember(_ memberID: String, in groupID: String, reason: String) async throws -> Report {
        try await send("POST", "groups/\(groupID)/members/\(memberID)/report", body: try JSONEncoder().encode(["reason": reason]))
    }

    /// Hides the member's items from this device only.
    public func block(memberID: String, in groupID: String) async throws {
        _ = try await sendForData("POST", "groups/\(groupID)/members/\(memberID)/block")
    }

    public func unblock(memberID: String, in groupID: String) async throws {
        _ = try await sendForData("DELETE", "groups/\(groupID)/members/\(memberID)/block")
    }

    public func openReports(of groupID: String) async throws -> [Report] {
        try await send("GET", "groups/\(groupID)/reports")
    }

    public func review(_ reportID: String, in groupID: String, _ decision: ReportDecision) async throws -> Report {
        try await send("POST", "groups/\(groupID)/reports/\(reportID)/\(decision.rawValue)")
    }
}
