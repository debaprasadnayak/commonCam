import CommonCamKit
import StoreKit
import SwiftUI

struct ContentView: View {
    let api: APIClient
    let purchaser: TierPurchaser

    @State private var groups: [EventGroup] = []
    @State private var products: [PaidTier: Product] = [:]
    @State private var selectedTier = PaidTier.preselected
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var joinRequest: JoinRequest?
    @State private var joined: [Membership] = []

    var body: some View {
        NavigationStack {
            List {
                Section("New group") {
                    Picker("Tier", selection: $selectedTier) {
                        ForEach(PaidTier.allCases, id: \.self) { tier in
                            tierLabel(tier).tag(tier)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("Buy \(products[selectedTier]?.displayName ?? selectedTier.rawValue.capitalized)") {
                        Task { await buy() }
                    }
                    .disabled(isCreating || products[selectedTier] == nil)
                    Button("Create free Taster group") {
                        Task { await createGroup() }
                    }
                    .disabled(isCreating)
                }
                Section {
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
                PhotosSettingsSection()
            }
            .navigationTitle("commonCam")
            .task { await loadGroups() }
            // Lives as long as the root view: Ask to Buy approvals etc. are activated while the app runs.
            .task { await purchases.processUpdates { _ in await loadGroups() } }
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

    private func tierLabel(_ tier: PaidTier) -> some View {
        HStack {
            Text(products[tier]?.displayName ?? tier.rawValue.capitalized)
            if tier == PaidTier.preselected {
                Text("Most popular").font(.caption).padding(.horizontal, 6).background(.tint.opacity(0.2), in: .capsule)
            }
            Spacer()
            Text(products[tier]?.displayPrice ?? "").foregroundStyle(.secondary)
        }
    }

    private var purchases: PurchaseRouter {
        PurchaseRouter(handlers: [purchaser.handle, GroupPurchaser(api: api).handle])
    }

    private func loadGroups() async {
        // Purchases whose activation failed earlier (e.g. offline) are activated here.
        _ = await purchases.processUnfinished()
        do {
            products = try await purchaser.products()
            groups = try await api.myGroups()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load groups: \(error.localizedDescription)"
        }
    }

    private func buy() async {
        isCreating = true
        defer { isCreating = false }
        do {
            if let group = try await purchaser.purchase(selectedTier) { groups.insert(group, at: 0) }
            errorMessage = nil
        } catch {
            errorMessage = "Purchase not activated yet; it will retry automatically. (\(error.localizedDescription))"
        }
    }

    private func createGroup() async {
        isCreating = true
        defer { isCreating = false }
        do {
            groups.insert(try await api.createTasterGroup(), at: 0)
            errorMessage = nil
        } catch let error as APIError where error.statusCode == 403 {
            errorMessage = "You've used this device's free Taster. Pick a paid tier for your next group."
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

    @State private var pin: String?
    @State private var isEnteringPin = false

    var body: some View {
        NavigationStack {
            if let qrToken {
                JoinView(api: api, code: .qrToken(qrToken), onJoined: onJoined)
            } else if let pin {
                JoinView(api: api, code: .pin(pin), onJoined: onJoined)
            } else if isEnteringPin {
                PinEntryView { pin = $0 }
                    .toolbar { Button("Scan QR") { isEnteringPin = false } }
            } else {
                ScannerView { qrToken = $0 }
                    .toolbar { Button("Enter PIN") { isEnteringPin = true } }
            }
        }
    }
}
