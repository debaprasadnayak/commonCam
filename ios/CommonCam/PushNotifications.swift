import CommonCamKit
import os
import UIKit
import UserNotifications

/// Grace reminders and storage warnings (#19): asks for permission, registers with APNs and hands the device
/// token to the API. Without permission nothing is registered and the server simply skips this device.
@MainActor
enum PushNotifications {
    /// Set at launch; receives the APNs device token.
    static var api: APIClient?
    static let log = Logger(subsystem: "app.commoncam.CommonCam", category: "push")

    /// Prompts once; later launches re-register silently (APNs tokens can change).
    static func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task {
            do {
                try await PushNotifications.api?.registerPushToken(deviceToken)
            } catch {
                PushNotifications.log.error("Sending the push token failed: \(error)")
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.log.error("APNs registration failed: \(error)")
    }

    /// Show reminders and storage warnings even while the app is open (the host is often in it when storage fills).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
