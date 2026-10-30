import CommonCamKit
import StoreKit

/// Buys upgrades and add-ons for an existing group with StoreKit 2. The group id travels in the
/// transaction's `appAccountToken`, so the server can bind the payment to that group and a failed
/// application can be retried from `Transaction.unfinished` after a relaunch.
@MainActor
final class GroupPurchaser {
    typealias Apply = @MainActor (_ signedTransaction: String, _ groupID: String) async throws -> EventGroup
    typealias Buy = TierPurchaser.Buy

    struct Offer {
        let purchase: GroupPurchase
        let product: Product
    }

    enum PurchaseError: Error {
        case productUnavailable
        case unverifiedTransaction
    }

    private let apply: Apply
    private let buy: Buy

    init(apply: @escaping Apply, buy: @escaping Buy = { try await $0.purchase(options: $1) }) {
        self.apply = apply
        self.buy = buy
    }

    convenience init(api: APIClient) {
        self.init { try await api.applyPurchase(signedTransaction: $0, to: $1) }
    }

    /// What the group can buy, in `GroupPurchase.available(for:)` order, skipping products StoreKit lacks.
    func offers(for group: EventGroup) async throws -> [Offer] {
        let purchases = GroupPurchase.available(for: group)
        let products = try await Product.products(for: purchases.map(\.productID))
        return purchases.compactMap { purchase in
            products.first { $0.id == purchase.productID }.map { Offer(purchase: purchase, product: $0) }
        }
    }

    /// Returns the group with its new limits, or nil if the host cancelled or it awaits approval (Ask to Buy).
    func purchase(_ purchase: GroupPurchase, for group: EventGroup) async throws -> EventGroup? {
        guard let token = UUID(uuidString: group.id),
              let product = try await Product.products(for: [purchase.productID]).first
        else { throw PurchaseError.productUnavailable }
        switch try await buy(product, [.appAccountToken(token)]) {
        case .success(let verification):
            return try await applyAndFinish(verification)
        case .userCancelled, .pending:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Applies upgrades/add-ons whose earlier application failed (e.g. offline). Call on launch.
    func applyUnfinished() async -> [EventGroup] {
        var groups: [EventGroup] = []
        for await verification in Transaction.unfinished {
            guard GroupPurchase(productID: verification.unsafePayloadValue.productID) != nil else { continue }
            if let group = try? await applyAndFinish(verification) { groups.append(group) }
        }
        return groups
    }

    private func applyAndFinish(_ verification: VerificationResult<Transaction>) async throws -> EventGroup? {
        // The server re-verifies the JWS; this local check only avoids sending obvious junk.
        guard case .verified(let transaction) = verification,
              GroupPurchase(productID: transaction.productID) != nil,
              let groupID = transaction.appAccountToken?.uuidString.lowercased()
        else { throw PurchaseError.unverifiedTransaction }
        do {
            let group = try await apply(verification.jwsRepresentation, groupID)
            await transaction.finish()
            return group
        } catch let error as APIError where error.statusCode == 409 {
            // Already applied by an earlier attempt whose response was lost.
            await transaction.finish()
            return nil
        }
    }
}
