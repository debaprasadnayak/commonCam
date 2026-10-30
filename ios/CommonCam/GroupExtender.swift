import CommonCamKit
import StoreKit
import SwiftUI

/// Buys the paid extension for an ended group (Grace → Active). Like `TierPurchaser`, a transaction is
/// finished only once the API has accepted it; the group id travels as the `appAccountToken`, so an
/// unfinished extension is redeemed for the right group later.
@MainActor
final class GroupExtender {
    typealias Extend = @MainActor (_ groupID: String, _ signedTransaction: String) async throws -> EventGroup
    typealias Buy = TierPurchaser.Buy

    enum ExtensionError: Error {
        case productUnavailable
        case unverifiedTransaction
        case invalidGroup
    }

    private let extend: Extend
    private let buy: Buy

    init(extend: @escaping Extend, buy: @escaping Buy = { try await $0.purchase(options: $1) }) {
        self.extend = extend
        self.buy = buy
    }

    convenience init(api: APIClient) {
        self.init { try await api.extendGroup($0, signedTransaction: $1) }
    }

    func product() async throws -> Product? {
        try await Product.products(for: [GroupExtension.productID]).first
    }

    /// Returns nil if the host cancelled or the purchase awaits approval (Ask to Buy).
    func purchase(for groupID: String) async throws -> EventGroup? {
        guard let token = GroupExtension.appAccountToken(forGroup: groupID) else { throw ExtensionError.invalidGroup }
        guard let product = try await product() else { throw ExtensionError.productUnavailable }
        switch try await buy(product, [.appAccountToken(token)]) {
        case .success(let verification):
            return try await extendAndFinish(verification)
        case .userCancelled, .pending:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Redeems extensions whose earlier request failed (e.g. offline). Call on launch.
    func extendUnfinished() async -> [EventGroup] {
        var groups: [EventGroup] = []
        for await verification in StoreKit.Transaction.unfinished where verification.unsafePayloadValue.productID == GroupExtension.productID {
            if let group = try? await extendAndFinish(verification) { groups.append(group) }
        }
        return groups
    }

    private func extendAndFinish(_ verification: VerificationResult<StoreKit.Transaction>) async throws -> EventGroup? {
        guard case .verified(let transaction) = verification,
              transaction.productID == GroupExtension.productID,
              let token = transaction.appAccountToken
        else { throw ExtensionError.unverifiedTransaction }
        do {
            let group = try await extend(GroupExtension.groupID(fromAppAccountToken: token), verification.jwsRepresentation)
            await transaction.finish()
            return group
        } catch let error as APIError where error.statusCode == 409 || error.statusCode == 410 {
            // 409: already redeemed by an earlier attempt whose response was lost. 410: the group was
            // deleted before the extension arrived; nothing left to extend (refund via Apple).
            await transaction.finish()
            return nil
        }
    }
}

/// Shown to the host of an ended group: downloads until grace ends, and the paid extension.
/// Once extended, the reopened group replaces `group`, so this section gives way to the active-group ones.
struct GraceSection: View {
    let api: APIClient
    @Binding var group: EventGroup

    @State private var product: Product?
    @State private var errorMessage: String?
    @State private var isBuying = false

    private var extender: GroupExtender { GroupExtender(api: api) }

    var body: some View {
        Section("Event ended") {
            if let graceEndsAt = group.graceEndsAt {
                Text("Read-only. Save what you want before \(graceEndsAt.formatted(date: .abbreviated, time: .shortened)); after that the photos and videos are deleted from our servers.")
            }
            Button("Extend 7 days \(product.map { "for \($0.displayPrice)" } ?? "")") { Task { await buy() } }
                .disabled(product == nil || isBuying)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .task { product = try? await extender.product() }
    }

    private func buy() async {
        isBuying = true
        defer { isBuying = false }
        do {
            if let extended = try await extender.purchase(for: group.id) { group = extended }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't extend: \(error.localizedDescription)"
        }
    }
}
