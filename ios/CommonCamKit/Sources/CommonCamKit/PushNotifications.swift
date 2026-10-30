import Foundation

extension APIClient {
    /// Sends the APNs device token (from `didRegisterForRemoteNotificationsWithDeviceToken`) so this device gets
    /// grace reminders and, as host/co-host, storage warnings. Devices that never register are simply skipped.
    public func registerPushToken(_ deviceToken: Data) async throws {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        _ = try await sendForData("PUT", "devices/push-token", body: try JSONEncoder().encode(["token": hex]))
    }
}
