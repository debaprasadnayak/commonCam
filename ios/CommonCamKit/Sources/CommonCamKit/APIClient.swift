import Foundation

/// A host's time-boxed shared album, as returned by the API.
/// Named `EventGroup` to avoid clashing with SwiftUI's `Group`.
public struct EventGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let tier: String
    public let state: String
    public let peopleCap: Int
    public let storageCapBytes: Int64
    public let storageUsedBytes: Int64
    public let startsAt: Date
    public let endsAt: Date
}

/// What the host shows as a QR code. `joinUrl` is a universal link that falls back to the App Store.
public struct Invite: Codable, Equatable, Sendable {
    public let qrToken: String
    public let joinUrl: URL
    public let joiningPaused: Bool

    public init(qrToken: String, joinUrl: URL, joiningPaused: Bool) {
        self.qrToken = qrToken
        self.joinUrl = joinUrl
        self.joiningPaused = joiningPaused
    }
}

/// A guest in a group, with the fun name and colour they picked.
public struct Member: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let colour: String
    public let role: String
    /// "active", or "pending" while the host has approve-new-members on and hasn't decided yet.
    public let status: String
    public let consentAcceptedAt: Date
    public let joinedAt: Date
}

/// The result of joining: the group and this device's membership in it.
public struct Membership: Codable, Equatable, Sendable {
    public let group: EventGroup
    public let member: Member

    /// Waiting for the host or a co-host to approve; the group's members and photos stay hidden until then.
    public var isPending: Bool { member.status == "pending" }
}

private struct ApprovalToggle: Codable {
    let approvalRequired: Bool
}

struct PinState: Decodable {
    let pin: String?
}

public struct APIError: Error, Equatable {
    public let statusCode: Int
}

/// Talks to the commonCam Worker API. Every request carries the device token.
public struct APIClient: Sendable {
    private let baseURL: URL
    private let identity: DeviceIdentity
    private let session: URLSession

    public init(baseURL: URL, identity: DeviceIdentity, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.identity = identity
        self.session = session
    }

    public func createTasterGroup() async throws -> EventGroup {
        try await send("POST", "groups", body: Data(#"{"tier":"taster"}"#.utf8))
    }

    public func myGroups() async throws -> [EventGroup] {
        try await send("GET", "groups")
    }

    public func invite(for groupID: String) async throws -> Invite {
        try await send("GET", "groups/\(groupID)/invite")
    }

    public func members(of groupID: String) async throws -> [Member] {
        try await send("GET", "groups/\(groupID)/members")
    }

    /// The group's join PIN, or nil while PIN joining is off (the default). Host only.
    public func pin(for groupID: String) async throws -> String? {
        let state: PinState = try await send("GET", "groups/\(groupID)/pin")
        return state.pin
    }

    /// Turns PIN joining on, or replaces the PIN so the old one stops working. Host only.
    public func rotatePin(for groupID: String) async throws -> String {
        let state: PinState = try await send("POST", "groups/\(groupID)/pin")
        guard let pin = state.pin else { throw APIError(statusCode: 500) }
        return pin
    }

    public func turnOffPin(for groupID: String) async throws {
        let _: PinState = try await send("DELETE", "groups/\(groupID)/pin")
    }

    /// Joins the group behind a scanned QR. The server refuses unless `consentAccepted` is true.
    public func join(qrToken: String, displayName: String, colour: String, consentAccepted: Bool) async throws -> Membership {
        try await join(["qrToken": qrToken], displayName: displayName, colour: colour, consentAccepted: consentAccepted)
    }

    /// Joins with the host's typed PIN instead of a QR; same server-side checks as a QR join.
    public func join(pin: String, displayName: String, colour: String, consentAccepted: Bool) async throws -> Membership {
        try await join(["pin": pin], displayName: displayName, colour: colour, consentAccepted: consentAccepted)
    }

    private func join(_ code: [String: String], displayName: String, colour: String, consentAccepted: Bool) async throws -> Membership {
        var body: [String: any Sendable] = ["displayName": displayName, "colour": colour, "consent": consentAccepted]
        body.merge(code) { _, new in new }
        return try await send("POST", "join", body: try JSONSerialization.data(withJSONObject: body))
    }

    public func approvalRequired(for groupID: String) async throws -> Bool {
        let toggle: ApprovalToggle = try await send("GET", "groups/\(groupID)/approval")
        return toggle.approvalRequired
    }

    /// Host or co-host: when on, new joins wait in `pendingMembers` until approved or rejected.
    @discardableResult
    public func setApprovalRequired(_ required: Bool, for groupID: String) async throws -> Bool {
        let body = try JSONEncoder().encode(ApprovalToggle(approvalRequired: required))
        let toggle: ApprovalToggle = try await send("PUT", "groups/\(groupID)/approval", body: body)
        return toggle.approvalRequired
    }

    public func pendingMembers(of groupID: String) async throws -> [Member] {
        try await send("GET", "groups/\(groupID)/pending")
    }

    @discardableResult
    public func approve(memberID: String, in groupID: String) async throws -> Member {
        try await send("POST", "groups/\(groupID)/members/\(memberID)/approve")
    }

    public func reject(memberID: String, in groupID: String) async throws {
        _ = try await sendForData("POST", "groups/\(groupID)/members/\(memberID)/reject")
    }

    public func gallery(of groupID: String) async throws -> [GalleryItem] {
        try await send("GET", "groups/\(groupID)/items")
    }

    /// Asks for an upload URL (the server checks the group is open, we are a member and it fits the cap),
    /// uploads the original byte-for-byte, then confirms so it appears in the gallery.
    public func share(_ photo: CapturedPhoto, in groupID: String) async throws -> GalleryItem {
        let ask: [String: any Sendable] = ["bytes": photo.data.count, "contentType": photo.format.contentType]
        let ticket: UploadTicket = try await send(
            "POST", "groups/\(groupID)/uploads", body: try JSONSerialization.data(withJSONObject: ask)
        )
        try await upload(photo, to: ticket)
        let confirm = try JSONSerialization.data(withJSONObject: ["itemId": ticket.itemId])
        return try await send("POST", "groups/\(groupID)/items", body: confirm)
    }

    /// The signed URL is the credential, so no device token is sent with the bytes.
    private func upload(_ photo: CapturedPhoto, to ticket: UploadTicket) async throws {
        var request = URLRequest(url: ticket.uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(photo.format.contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: photo.data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(statusCode: status) }
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        try Self.decoder.decode(T.self, from: try await sendForData(method, path, body: body))
    }

    func sendForData(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(try identity.token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(statusCode: status) }
        return data
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        }
        return decoder
    }()
}
