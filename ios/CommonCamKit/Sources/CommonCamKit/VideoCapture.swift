import Foundation

/// Decides, frame by frame, what goes into one video clip. SPEC: clips are capped at 60 seconds.
///
/// Times are sample timestamps in seconds (`CMTime.seconds`). The first video frame starts the clip; any frame
/// `maxDuration` or more after it stops the clip, so a recording can never run past the cap even if the UI lags.
public struct ClipRecording: Sendable {
    public static let maxDuration: TimeInterval = 60

    public enum Decision: Equatable, Sendable {
        /// Write this frame.
        case record
        /// The clip is over: drop this frame and finish the file.
        case stop
    }

    public private(set) var startTime: TimeInterval?
    public private(set) var isFinished = false

    public init() {}

    public mutating func frame(at time: TimeInterval) -> Decision {
        guard !isFinished else { return .stop }
        guard let startTime else {
            startTime = time
            return .record
        }
        if time - startTime >= Self.maxDuration {
            isFinished = true
            return .stop
        }
        return .record
    }

    /// The user tapped stop.
    public mutating func stop() {
        isFinished = true
    }

    /// Sound is written only alongside the pictures: after the first frame and before the cap.
    public func acceptsAudio(at time: TimeInterval) -> Bool {
        guard let startTime, !isFinished else { return false }
        return time >= startTime && time - startTime < Self.maxDuration
    }

    public func remaining(at time: TimeInterval) -> TimeInterval {
        guard let startTime else { return Self.maxDuration }
        return min(Self.maxDuration, max(0, Self.maxDuration - (time - startTime)))
    }

    /// "m:ss", rounded up so the countdown shows 0:00 only when the clip is over.
    public static func countdownLabel(remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// A finished recording: an HEVC QuickTime movie on disk. Clips are large, so they travel as files, never as `Data`.
/// Video filters are baked into the frames at capture (#8), so a clip never carries a filter recipe.
public struct CapturedVideo: Sendable {
    public static let contentType = "video/quicktime"
    public static let fileExtension = "mov"

    public let file: URL

    public init(file: URL) {
        self.file = file
    }
}

extension GalleryItem {
    /// Plays with AVKit instead of showing a still.
    public var isVideo: Bool { type == "video" }
}

extension QueuedUpload {
    public var isVideo: Bool { contentType.hasPrefix("video/") }
}
