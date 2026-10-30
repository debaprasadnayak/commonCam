import CommonCamKit
import SwiftUI

/// The host's view of a group: the QR guests scan and the members who have joined.
struct HostGroupView: View {
    let api: APIClient
    let group: EventGroup

    @State private var invite: Invite?
    @State private var errorMessage: String?

    var body: some View {
        List {
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
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            ApprovalSection(api: api, group: group)
            MembersSection(api: api, group: group)
        }
        .navigationTitle(group.tier.capitalized)
        .task {
            do {
                invite = try await api.invite(for: group.id)
            } catch {
                errorMessage = "Couldn't load the QR code: \(error.localizedDescription)"
            }
        }
    }
}

/// Member list that refreshes every few seconds while visible, so the host sees guests arrive.
struct MembersSection: View {
    let api: APIClient
    let group: EventGroup

    @State private var members: [Member] = []

    var body: some View {
        Section("Members (\(members.count + 1) of \(group.peopleCap), including host)") {
            ForEach(members) { member in
                Label {
                    Text(member.displayName)
                } icon: {
                    Circle().fill(Color(hex: member.colour)).frame(width: 14, height: 14)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let latest = try? await api.members(of: group.id) { members = latest }
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
