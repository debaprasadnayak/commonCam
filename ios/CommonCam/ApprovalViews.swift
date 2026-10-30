import CommonCamKit
import SwiftUI

/// Host/co-host: the approve-new-members toggle and the requests waiting on it. Polls while visible.
struct ApprovalSection: View {
    let api: APIClient
    let group: EventGroup

    @State private var approvalRequired = false
    @State private var pending: [Member] = []
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Approve new members", isOn: Binding(get: { approvalRequired }, set: { setApproval($0) }))
            ForEach(pending) { member in
                HStack {
                    Label {
                        Text(member.displayName)
                    } icon: {
                        Circle().fill(Color(hex: member.colour)).frame(width: 14, height: 14)
                    }
                    Spacer()
                    Button("Reject", systemImage: "xmark.circle") { decide(member, approve: false) }
                        .labelStyle(.iconOnly).tint(.red)
                    Button("Approve", systemImage: "checkmark.circle.fill") { decide(member, approve: true) }
                        .labelStyle(.iconOnly).tint(.green)
                }
                .buttonStyle(.borderless)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        } header: {
            Text(pending.isEmpty ? "Joining" : "Waiting for approval (\(pending.count))")
        } footer: {
            Text("When on, people who scan the QR wait here until you approve them.")
        }
        .task {
            if let required = try? await api.approvalRequired(for: group.id) { approvalRequired = required }
            while !Task.isCancelled {
                if let latest = try? await api.pendingMembers(of: group.id) { pending = latest }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func setApproval(_ required: Bool) {
        approvalRequired = required
        Task {
            do {
                approvalRequired = try await api.setApprovalRequired(required, for: group.id)
                errorMessage = nil
            } catch {
                approvalRequired = !required
                errorMessage = "Couldn't change the setting."
            }
        }
    }

    private func decide(_ member: Member, approve: Bool) {
        Task {
            do {
                if approve {
                    try await api.approve(memberID: member.id, in: group.id)
                } else {
                    try await api.reject(memberID: member.id, in: group.id)
                }
                pending.removeAll { $0.id == member.id }
                errorMessage = nil
            } catch let error as APIError where error.statusCode == 409 {
                errorMessage = "The group is full."
            } catch {
                errorMessage = "Couldn't update \(member.displayName)."
            }
        }
    }
}

/// A guest's view of a joined group. While pending, the server hides the members, so keep checking until approved.
struct GuestGroupView: View {
    let api: APIClient
    let membership: Membership

    @State private var approved = false

    var body: some View {
        List {
            if approved || !membership.isPending {
                MembersSection(api: api, group: membership.group)
            } else {
                Section { Label("Waiting for the host to approve you", systemImage: "hourglass") }
            }
        }
        .navigationTitle(membership.member.displayName)
        .task {
            guard membership.isPending else { return }
            while !Task.isCancelled && !approved {
                if (try? await api.members(of: membership.group.id)) != nil { approved = true }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
