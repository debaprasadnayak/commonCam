import Foundation

extension APIClient {
    /// Deletes an item from the group for everyone. Already-deleted items succeed; others' items throw 403 unless host/co-host.
    public func deleteItem(_ itemID: String, in groupID: String) async throws {
        _ = try await sendForData("DELETE", "groups/\(groupID)/items/\(itemID)")
    }
}
