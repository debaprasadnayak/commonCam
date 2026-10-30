import Foundation

/// What a host or co-host can do to a member. Removed members may rejoin; banned devices may not.
public enum MemberAction: String, CaseIterable, Sendable {
    case remove
    case ban
    case makeCoHost = "co-host"
}

/// Host controls. The server allows these for the host and for co-hosts.
extension APIClient {
    /// Returns whether joining is now paused.
    public func setJoiningPaused(_ paused: Bool, for groupID: String) async throws -> Bool {
        struct State: Decodable { let joiningPaused: Bool }
        let body = Data(#"{"paused":\#(paused)}"#.utf8)
        let state: State = try await send("PUT", "groups/\(groupID)/joining", body: body)
        return state.joiningPaused
    }

    /// Issues a new QR token; the old one stops working.
    public func rotateInvite(for groupID: String) async throws -> Invite {
        try await send("POST", "groups/\(groupID)/invite/rotate")
    }

    public func perform(_ action: MemberAction, on memberID: String, in groupID: String) async throws {
        _ = try await sendForData("POST", "groups/\(groupID)/members/\(memberID)/\(action.rawValue)")
    }
}
