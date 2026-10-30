import Foundation

/// Sends part files with a background `URLSession`, so parts keep uploading while the app is suspended or killed.
///
/// Parts are tagged with their `taskID`; after a relaunch an `upload` for a part that is still in flight waits for
/// that task instead of starting a second one. Parts that finish while nobody waits are picked up by the queue's
/// next run, which asks the server which parts it has.
public final class BackgroundUploadTransport: NSObject, PartTransport, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var pendingEventsCompletion: (() -> Void)?
    private var session: URLSession!

    /// `configuration` is normally `URLSessionConfiguration.background(withIdentifier:)`.
    public init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public static func background(identifier: String) -> BackgroundUploadTransport {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return BackgroundUploadTransport(configuration: configuration)
    }

    /// Hand over the completion handler from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func handleBackgroundEvents(completion: @escaping () -> Void) {
        lock.withLock { pendingEventsCompletion = completion }
    }

    /// The signed URL is the credential, so no device token is sent with the bytes.
    public func upload(file: URL, to url: URL, taskID: String) async throws {
        let running = await session.allTasks.first { $0.taskDescription == taskID && $0.state == .running }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let missed: [CheckedContinuation<Void, Error>] = lock.withLock {
                waiters[taskID, default: []].append(continuation)
                guard running?.state == .completed else { return [] }
                return waiters.removeValue(forKey: taskID) ?? []
            }
            // It finished between the lookup and now; the queue's next run asks the server whether it arrived.
            if !missed.isEmpty { return missed.forEach { $0.resume(throwing: URLError(.unknown)) } }
            guard running == nil else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = taskID
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskID = task.taskDescription else { return }
        let continuations = lock.withLock { waiters.removeValue(forKey: taskID) ?? [] }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        for continuation in continuations {
            if let error {
                continuation.resume(throwing: error)
            } else if !(200..<300).contains(status) {
                continuation.resume(throwing: APIError(statusCode: status))
            } else {
                continuation.resume()
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { pendingEventsCompletion = nil }
            return pendingEventsCompletion
        }
        DispatchQueue.main.async { completion?() }
    }
}
