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
    @State private var isBusy = false

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
                    .disabled(isBusy || products[selectedTier] == nil)
                    Button("Create free Taster group") {
                        Task { await createGroup() }
                    }
                    .disabled(isBusy)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("My groups") {
                    ForEach(groups) { group in
                        VStack(alignment: .leading) {
                            Text("\(group.tier.capitalized) · \(group.state)").font(.headline)
                            Text("\(group.peopleCap) people · \(ByteCountFormatter.string(fromByteCount: group.storageCapBytes, countStyle: .binary))")
                            Text("Ends \(group.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("commonCam")
            .task { await refresh() }
            .refreshable { await refresh() }
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

    private func refresh() async {
        // Purchases whose activation failed earlier (offline, Ask to Buy) are activated here.
        _ = await purchaser.activateUnfinished()
        do {
            products = try await purchaser.products()
            groups = try await api.myGroups()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load: \(error.localizedDescription)"
        }
    }

    private func buy() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if let group = try await purchaser.purchase(selectedTier) { groups.insert(group, at: 0) }
            errorMessage = nil
        } catch {
            errorMessage = "Purchase not activated yet; it will retry automatically. (\(error.localizedDescription))"
        }
    }

    private func createGroup() async {
        isBusy = true
        defer { isBusy = false }
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
