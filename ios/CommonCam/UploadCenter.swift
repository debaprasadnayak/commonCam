import CommonCamKit
import SwiftUI
import UIKit

/// The app's single upload queue: shots are persisted in Application Support and sent with a background
/// URLSession, so they survive the app being killed, a restart or a dead venue Wi-Fi. Views read `uploads` for
/// pending badges and `confirmed` for items that just reached the gallery.
@MainActor @Observable
final class UploadCenter {
    /// Must exist from launch: iOS relaunches the app to deliver background session events to it.
    static let transport = BackgroundUploadTransport.background(identifier: "app.commoncam.CommonCam.uploads")
    private static let retryInterval: Duration = .seconds(15)

    private(set) var uploads: [QueuedUpload] = []
    private(set) var confirmed: [GalleryItem] = []
    private(set) var problem: String?
    private let queue: UploadQueue

    init(api: APIClient) {
        let directory = URL.applicationSupportDirectory.appending(path: "UploadQueue", directoryHint: .isDirectory)
        queue = UploadQueue(directory: directory, service: api, transport: Self.transport)
        Task { [queue] in
            await queue.observe { uploads in Task { @MainActor in self.uploads = uploads } }
            await self.keepSending()
        }
    }

    func enqueue(_ photo: CapturedPhoto, in groupID: String) async {
        do {
            try await queue.enqueue(photo, in: groupID)
            problem = nil
            await send()
        } catch {
            problem = "Couldn't save the photo: \(error.localizedDescription)"
        }
    }

    func remove(_ upload: QueuedUpload) async {
        await queue.remove(upload.id)
    }

    func originalFile(of upload: QueuedUpload) -> URL {
        queue.originalFile(of: upload)
    }

    /// Runs the queue now, e.g. after a capture or when the app comes back to the foreground.
    func send() async {
        let items = await queue.run()
        if !items.isEmpty { confirmed.append(contentsOf: items) }
    }

    private func keepSending() async {
        while true {
            await send()
            try? await Task.sleep(for: Self.retryInterval)
        }
    }
}

/// Hands background URLSession events to the upload transport when iOS relaunches the app for them.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        UploadCenter.transport.handleBackgroundEvents(completion: completionHandler)
    }
}

extension QueuedUpload {
    /// What the badge on a not-yet-confirmed tile says when the server refused the shot.
    var failureMessage: String? {
        switch failure {
        case nil: nil
        case 410: "The group has ended"
        case 413: "The group's storage stayed full"
        case 404, 403: "You're no longer in this group"
        case let status?: "Not shared (error \(status))"
        }
    }
}
