import CommonCamKit
import StoreKit

/// Buys paid tiers with StoreKit 2 and hands the signed transaction to the API, which verifies it
/// and activates the group. A transaction is finished only once the API has accepted it, so a
/// failed activation is retried from `Transaction.unfinished` instead of losing the payment.
@MainActor
final class TierPurchaser {
    typealias Activate = @MainActor (PaidTier, _ signedTransaction: String) async throws -> EventGroup

    enum PurchaseError: Error {
        case productUnavailable
        case unverifiedTransaction
    }

    private let activate: Activate

    init(activate: @escaping Activate) {
        self.activate = activate
    }

    func products() async throws -> [PaidTier: Product] {
        let products = try await Product.products(for: PaidTier.allCases.map(\.productID))
        return Dictionary(uniqueKeysWithValues: products.compactMap { product in
            PaidTier(productID: product.id).map { ($0, product) }
        })
    }

    /// Returns nil if the host cancelled or the purchase awaits approval (Ask to Buy).
    func purchase(_ tier: PaidTier) async throws -> EventGroup? {
        guard let product = try await Product.products(for: [tier.productID]).first else {
            throw PurchaseError.productUnavailable
        }
        switch try await product.purchase() {
        case .success(let verification):
            return try await activateAndFinish(verification)
        case .userCancelled, .pending:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Activates purchases whose earlier activation failed (e.g. offline). Call on launch.
    func activateUnfinished() async -> [EventGroup] {
        var groups: [EventGroup] = []
        for await verification in Transaction.unfinished {
            if let group = try? await activateAndFinish(verification) { groups.append(group) }
        }
        return groups
    }

    private func activateAndFinish(_ verification: VerificationResult<Transaction>) async throws -> EventGroup? {
        // The server re-verifies the JWS; this local check only avoids sending obvious junk.
        guard case .verified(let transaction) = verification,
              let tier = PaidTier(productID: transaction.productID)
        else { throw PurchaseError.unverifiedTransaction }
        do {
            let group = try await activate(tier, verification.jwsRepresentation)
            await transaction.finish()
            return group
        } catch let error as APIError where error.statusCode == 409 {
            // Already activated by an earlier attempt whose response was lost.
            await transaction.finish()
            return nil
        }
    }
}
