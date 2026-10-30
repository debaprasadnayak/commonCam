import CommonCamKit
import SwiftUI

struct ContentView: View {
    let api: APIClient

    @State private var groups: [EventGroup] = []
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var joinRequest: JoinRequest?
    @State private var joined: [Membership] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Create free Taster group") {
                        Task { await createGroup() }
                    }
                    .disabled(isCreating)
                    Button("Join a group") { joinRequest = JoinRequest(qrToken: nil) }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if !joined.isEmpty {
                    Section("Joined") {
                        ForEach(joined, id: \.group.id) { membership in
                            NavigationLink {
                                if membership.isPending {
                                    GuestGroupView(api: api, membership: membership)
                                } else {
                                    HostGroupView(
                                        api: api, group: membership.group, title: membership.member.displayName, isHost: false
                                    )
                                }
                            } label: {
                                Text("\(membership.group.tier.capitalized) group as \(membership.member.displayName)"
                                    + (membership.isPending ? " (awaiting approval)" : ""))
                            }
                        }
                    }
                }
                Section("My groups") {
                    ForEach(groups) { group in
                        NavigationLink {
                            HostGroupView(api: api, group: group)
                        } label: {
                            VStack(alignment: .leading) {
                                Text("\(group.tier.capitalized) · \(group.state)").font(.headline)
                                Text("\(group.peopleCap) people · \(ByteCountFormatter.string(fromByteCount: group.storageCapBytes, countStyle: .binary))")
                                Text("Ends \(group.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("commonCam")
            .task { await loadGroups() }
            .refreshable { await loadGroups() }
            .onOpenURL { url in
                if let token = JoinLink.qrToken(from: url) { joinRequest = JoinRequest(qrToken: token) }
            }
            .sheet(item: $joinRequest) { request in
                JoinFlow(api: api, qrToken: request.qrToken) { membership in
                    joined.removeAll { $0.group.id == membership.group.id }
                    joined.insert(membership, at: 0)
                    joinRequest = nil
                }
            }
        }
    }

    private func loadGroups() async {
        do {
            groups = try await api.myGroups()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load groups: \(error.localizedDescription)"
        }
    }

    private func createGroup() async {
        isCreating = true
        defer { isCreating = false }
        do {
            groups.insert(try await api.createTasterGroup(), at: 0)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't create group: \(error.localizedDescription)"
        }
    }
}

/// A join started from the in-app button (no token yet) or from a scanned universal link.
struct JoinRequest: Identifiable {
    let id = UUID()
    let qrToken: String?
}

private struct JoinFlow: View {
    let api: APIClient
    @State var qrToken: String?
    let onJoined: (Membership) -> Void

    var body: some View {
        NavigationStack {
            if let qrToken {
                JoinView(api: api, qrToken: qrToken, onJoined: onJoined)
            } else {
                ScannerView { qrToken = $0 }
            }
        }
    }
}
