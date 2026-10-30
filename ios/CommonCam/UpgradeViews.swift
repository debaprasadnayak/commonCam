import CommonCamKit
import StoreKit
import SwiftUI

/// Upgrades (pay only the difference) and add-ons for hosts and co-hosts. The new limits come back
/// from the API and replace `group` straight away.
struct UpgradeSection: View {
    let api: APIClient
    @Binding var group: EventGroup

    @State private var offers: [GroupPurchaser.Offer] = []
    @State private var isBuying = false
    @State private var errorMessage: String?

    private var purchaser: GroupPurchaser { GroupPurchaser(api: api) }

    var body: some View {
        Section {
            ForEach(offers, id: \.purchase) { offer in
                Button {
                    Task { await buy(offer.purchase) }
                } label: {
                    HStack {
                        Text(title(for: offer))
                        Spacer()
                        Text(offer.product.displayPrice).foregroundStyle(.secondary)
                    }
                }
                .disabled(isBuying)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        } header: {
            Text("Upgrade or add more")
        } footer: {
            Text("\(group.peopleCap) people · \(ByteCountFormatter.string(fromByteCount: group.storageCapBytes, countStyle: .binary)) · ends \(group.endsAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .task(id: group.tier) {
            offers = (try? await purchaser.offers(for: group)) ?? []
        }
    }

    private func title(for offer: GroupPurchaser.Offer) -> String {
        switch offer.purchase {
        case .upgrade(_, let to): "Upgrade to \(to.rawValue.capitalized) (pay the difference)"
        case .addOn(let addOn): addOn.title
        }
    }

    private func buy(_ purchase: GroupPurchase) async {
        isBuying = true
        defer { isBuying = false }
        do {
            if let updated = try await purchaser.purchase(purchase, for: group) { group = updated }
            errorMessage = nil
        } catch {
            errorMessage = "Purchase not applied yet; it will retry automatically. (\(error.localizedDescription))"
        }
    }
}
