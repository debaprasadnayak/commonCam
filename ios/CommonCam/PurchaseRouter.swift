import CommonCamKit
import StoreKit

/// The one path for transactions that don't come back from a `purchase(...)` call: unfinished ones (an earlier
/// activation failed, e.g. offline) and `Transaction.updates` (Ask to Buy approvals, interrupted purchases,
/// purchases on another device). Each handler takes only its own products and finishes a transaction only once
/// the API has accepted it; new product kinds (e.g. #18's extension) just add a handler.
@MainActor
struct PurchaseRouter {
    typealias Handler = @MainActor (VerificationResult<Transaction>) async -> EventGroup?

    let handlers: [Handler]

    func route(_ verification: VerificationResult<Transaction>) async -> EventGroup? {
        for handler in handlers {
            if let group = await handler(verification) { return group }
        }
        return nil
    }

    func processUnfinished() async -> [EventGroup] {
        var groups: [EventGroup] = []
        for await verification in Transaction.unfinished {
            if let group = await route(verification) { groups.append(group) }
        }
        return groups
    }

    /// Runs until cancelled; start it once at launch.
    func processUpdates(onGroup: @MainActor (EventGroup) async -> Void) async {
        for await verification in Transaction.updates {
            if let group = await route(verification) { await onGroup(group) }
        }
    }
}
