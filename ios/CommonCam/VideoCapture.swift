@preconcurrency import AVFoundation
import AVKit
import CommonCamKit
import Photos
import SwiftUI

/// Writes one HEVC clip from the camera's video and audio sample buffers with AVAssetWriter.
/// Every method runs on the camera's frames queue. `ClipRecording` decides which samples belong to the clip,
/// so the clip ends by itself at 60 s; the file is network-optimised (index first) so it streams from the gallery.
final class VideoRecorder: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noFrames, writeFailed
        var errorDescription: String? {
            switch self {
            case .noFrames: "The camera stopped before the video started. Try again."
            case .writeFailed: "The video couldn't be saved. Try again."
            }
        }
    }

    private struct Session {
        let file: URL
        let videoSettings: [String: Any]?
        let audioSettings: [String: Any]?
        let progress: @Sendable (TimeInterval) -> Void
        let completion: @Sendable (Result<CapturedVideo, Error>) -> Void
        var clip = ClipRecording()
        var writer: AVAssetWriter?
        var video: AVAssetWriterInput?
        var audio: AVAssetWriterInput?
        var lastReportedSecond: Int?
    }

    private var session: Session?
    private let lock = NSLock()
    private var recording = false

    /// Read from any queue, e.g. to hold the frame rotation steady while a clip is written.
    var isRecording: Bool { lock.withLock { recording } }

    func start(
        file: URL,
        videoSettings: [String: Any]?,
        audioSettings: [String: Any]?,
        progress: @escaping @Sendable (TimeInterval) -> Void,
        completion: @escaping @Sendable (Result<CapturedVideo, Error>) -> Void
    ) {
        guard session == nil else { return completion(.failure(Failure.writeFailed)) }
        session = Session(file: file, videoSettings: videoSettings, audioSettings: audioSettings, progress: progress, completion: completion)
        lock.withLock { recording = true }
    }

    func stop() {
        session?.clip.stop()
        finish()
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        guard var current = session else { return }
        let time = sample.presentationTimeStamp
        guard current.clip.frame(at: time.seconds) == .record else {
            session = current
            return finish()
        }
        if current.writer == nil {
            guard let pixels = sample.imageBuffer, startWriter(&current, size: CVImageBufferGetDisplaySize(pixels), at: time) else {
                session = current
                return finish()
            }
        }
        if let input = current.video, input.isReadyForMoreMediaData {
            input.append(sample)
        }
        let remaining = current.clip.remaining(at: time.seconds)
        let second = Int(remaining.rounded(.up))
        if second != current.lastReportedSecond {
            current.lastReportedSecond = second
            current.progress(remaining)
        }
        session = current
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard let current = session, current.writer?.status == .writing,
              current.clip.acceptsAudio(at: sample.presentationTimeStamp.seconds),
              let input = current.audio, input.isReadyForMoreMediaData
        else { return }
        input.append(sample)
    }

    /// The writer is created on the first frame so the clip has the frames' upright size.
    private func startWriter(_ current: inout Session, size: CGSize, at time: CMTime) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: current.file, fileType: .mov) else { return false }
        writer.shouldOptimizeForNetworkUse = true
        var settings = current.videoSettings ?? [:]
        settings[AVVideoCodecKey] = AVVideoCodecType.hevc
        settings[AVVideoWidthKey] = Int(size.width)
        settings[AVVideoHeightKey] = Int(size.height)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        if let audioSettings = current.audioSettings {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                current.audio = audio
            }
        }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        current.writer = writer
        current.video = video
        return true
    }

    private func finish() {
        guard let current = session else { return }
        session = nil
        lock.withLock { recording = false }
        guard let writer = current.writer, writer.status == .writing else {
            try? FileManager.default.removeItem(at: current.file)
            return current.completion(.failure(current.writer == nil ? Failure.noFrames : Failure.writeFailed))
        }
        current.video?.markAsFinished()
        current.audio?.markAsFinished()
        let (file, completion) = (current.file, current.completion)
        // The writer is done being used on the frames queue; only its outcome is read in the completion.
        nonisolated(unsafe) let finished = writer
        writer.finishWriting {
            if finished.status == .completed {
                completion(.success(CapturedVideo(file: file)))
            } else {
                try? FileManager.default.removeItem(at: file)
                completion(.failure(finished.error ?? Failure.writeFailed))
            }
        }
    }
}

/// Record / stop button with the time left in the clip. Recording also stops by itself at 60 s.
struct VideoShutter: View {
    let camera: Camera
    @Binding var isRecording: Bool
    let onRecord: (CapturedVideo) -> Void
    let onError: (String) -> Void
    @State private var remaining = ClipRecording.maxDuration

    var body: some View {
        VStack(spacing: 8) {
            Text(ClipRecording.countdownLabel(remaining: remaining))
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .background(isRecording ? Color.red : Color.clear, in: Capsule())
                .accessibilityLabel("\(Int(remaining.rounded(.up))) seconds left")
            Button {
                if isRecording { camera.stopRecording() } else { record() }
            } label: {
                Circle().strokeBorder(.white, lineWidth: 5).frame(width: 76, height: 76)
                    .overlay {
                        RoundedRectangle(cornerRadius: isRecording ? 6 : 30).fill(.red)
                            .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    }
            }
            .accessibilityLabel(isRecording ? "Stop recording" : "Record video")
        }
    }

    private func record() {
        isRecording = true
        remaining = ClipRecording.maxDuration
        Task {
            do {
                let clip = try await camera.record { left in
                    Task { @MainActor in remaining = left }
                }
                onRecord(clip)
            } catch {
                onError(error.localizedDescription)
            }
            isRecording = false
            remaining = ClipRecording.maxDuration
        }
    }
}

/// A still from a clip (remote or local), with a play badge.
struct VideoThumbnail: View {
    let url: URL
    var opacity = 1.0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().opacity(opacity)
            }
            Image(systemName: "play.circle.fill")
                .font(.title)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.4))
        }
        .task(id: url) { image = await Self.still(of: url) }
    }

    static func still(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        return try? await UIImage(cgImage: generator.image(at: .zero).image)
    }
}

/// Plays a gallery clip with AVKit, streaming from its signed download URL, and saves it to Photos.
struct VideoDetailView: View {
    let item: GalleryItem
    @State private var player: AVPlayer?
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        VStack {
            VideoPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let status {
                Text(status).font(.footnote)
            }
        }
        .padding()
        .navigationTitle(item.contributor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                Task { await save() }
            }
            .disabled(isSaving)
        }
        .task(id: item.id) {
            let player = AVPlayer(url: item.downloadUrl)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: item.downloadUrl)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let file = FileManager.default.temporaryDirectory.appending(path: "\(item.id).\(CapturedVideo.fileExtension)")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: downloaded, to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            status = switch await VideoSaver.save(file) {
            case .saved: "Saved the video."
            case .accessDenied: PhotosAccessMessage.denied
            default: "Couldn't save the video."
            }
        } catch {
            status = "Couldn't download the video."
        }
    }
}

/// Adds clips to the user's Photos library (add-only access), copying the file so the queue keeps its own.
enum VideoSaver {
    static func save(_ file: URL) async -> AutoSaveOutcome {
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else { return .accessDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
    }

    /// The fresh-capture safety net, honouring the same "Save my photos to Photos" setting as photos.
    static func autoSave(_ clip: CapturedVideo, enabled: Bool) async -> AutoSaveOutcome {
        enabled ? await save(clip.file) : .off
    }
}

/// Photo | Video switch above the shutter.
struct CaptureModePicker: View {
    @Binding var isVideo: Bool

    var body: some View {
        Picker("Mode", selection: $isVideo) {
            Text("Photo").tag(false)
            Text("Video").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
        .padding(.bottom, 8)
    }
}
