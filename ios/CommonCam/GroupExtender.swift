import CommonCamKit
import StoreKit
import SwiftUI

/// Buys the paid extension for an ended group (Grace → Active). Like `TierPurchaser`, a transaction is
/// finished only once the API has accepted it; the group id travels as the `appAccountToken`, so an
/// unfinished extension is redeemed for the right group later.
@MainActor
final class GroupExtender {
    typealias Extend = @MainActor (_ groupID: String, _ signedTransaction: String) async throws -> EventGroup

    enum ExtensionError: Error {
        case productUnavailable
        case unverifiedTransaction
        case invalidGroup
    }

    private let extend: Extend

    init(extend: @escaping Extend) {
        self.extend = extend
    }

    func product() async throws -> Product? {
        try await Product.products(for: [GroupExtension.productID]).first
    }

    /// Returns nil if the host cancelled or the purchase awaits approval (Ask to Buy).
    func purchase(for groupID: String) async throws -> EventGroup? {
        guard let token = GroupExtension.appAccountToken(forGroup: groupID) else { throw ExtensionError.invalidGroup }
        guard let product = try await product() else { throw ExtensionError.productUnavailable }
        switch try await product.purchase(options: [.appAccountToken(token)]) {
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
struct GraceSection: View {
    let api: APIClient
    let group: EventGroup

    @State private var product: Product?
    @State private var extended: EventGroup?
    @State private var errorMessage: String?
    @State private var isBuying = false

    private var extender: GroupExtender {
        GroupExtender { [api] groupID, signedTransaction in try await api.extendGroup(groupID, signedTransaction: signedTransaction) }
    }

    var body: some View {
        Section("Event ended") {
            if let extended {
                Text("Extended until \(extended.endsAt.formatted(date: .abbreviated, time: .shortened)). Pull to refresh your groups.")
            } else {
                if let graceEndsAt = group.graceEndsAt {
                    Text("Read-only. Save what you want before \(graceEndsAt.formatted(date: .abbreviated, time: .shortened)); after that the photos and videos are deleted from our servers.")
                }
                Button("Extend \(product.map { "for \($0.displayPrice)" } ?? "")") { Task { await buy() } }
                    .disabled(product == nil || isBuying)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .task { product = try? await extender.product() }
    }

    private func buy() async {
        isBuying = true
        defer { isBuying = false }
        do {
            if let group = try await extender.purchase(for: group.id) { extended = group }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't extend: \(error.localizedDescription)"
        }
    }
}
