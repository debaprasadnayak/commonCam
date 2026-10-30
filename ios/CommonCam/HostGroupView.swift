import CommonCamKit
import SwiftUI

/// A group as seen by its host or a member. Hosts and co-hosts also get the QR and host controls;
/// the invite only loads for them, so its presence decides what is shown.
struct HostGroupView: View {
    let api: APIClient
    let group: EventGroup
    var title: String?
    var isHost = true

    @State private var invite: Invite?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isHost || invite != nil {
                Section("Scan to join") {
                    if let invite, let image = QRCode.image(for: invite.joinUrl.absoluteString) {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Join QR code")
                        ShareLink("Share join link", item: invite.joinUrl)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            if let invite {
                Section("Host controls") {
                    Toggle("Pause joining", isOn: Binding(
                        get: { invite.joiningPaused },
                        set: { paused in Task { await setPaused(paused) } }
                    ))
                    Button("New QR code (old one stops working)") { Task { await rotate() } }
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            MembersSection(api: api, group: group, canManage: invite != nil)
        }
        .navigationTitle(title ?? group.tier.capitalized)
        .task {
            do {
                invite = try await api.invite(for: group.id)
            } catch {
                if isHost { errorMessage = "Couldn't load the QR code: \(error.localizedDescription)" }
            }
        }
    }

    private func setPaused(_ paused: Bool) async {
        guard let current = invite else { return }
        do {
            let now = try await api.setJoiningPaused(paused, for: group.id)
            invite = Invite(qrToken: current.qrToken, joinUrl: current.joinUrl, joiningPaused: now)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change joining: \(error.localizedDescription)"
        }
    }

    private func rotate() async {
        do {
            invite = try await api.rotateInvite(for: group.id)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't make a new QR code: \(error.localizedDescription)"
        }
    }
}

/// Member list that refreshes every few seconds while visible, so the host sees guests arrive.
/// Hosts and co-hosts can swipe a member to remove, ban, or make them co-host.
struct MembersSection: View {
    let api: APIClient
    let group: EventGroup
    var canManage = false

    @State private var members: [Member] = []

    var body: some View {
        Section("Members (\(members.count + 1) of \(group.peopleCap), including host)") {
            ForEach(members) { member in
                Label {
                    Text(member.role == "co-host" ? "\(member.displayName) · co-host" : member.displayName)
                } icon: {
                    Circle().fill(Color(hex: member.colour)).frame(width: 14, height: 14)
                }
                .swipeActions {
                    if canManage {
                        Button("Ban", role: .destructive) { Task { await perform(.ban, on: member) } }
                        Button("Remove") { Task { await perform(.remove, on: member) } }.tint(.orange)
                        if member.role != "co-host" {
                            Button("Co-host") { Task { await perform(.makeCoHost, on: member) } }.tint(.blue)
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func perform(_ action: MemberAction, on member: Member) async {
        try? await api.perform(action, on: member.id, in: group.id)
        await refresh()
    }

    private func refresh() async {
        if let latest = try? await api.members(of: group.id) { members = latest }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
