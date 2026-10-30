@preconcurrency import AVFoundation
import CommonCamKit
import SwiftUI

/// AVFoundation photo pipeline: back wide camera, maximum resolution, quality-prioritised HEIC (JPEG fallback).
/// All session work runs on `queue`; the format choice lives in `PhotoFormat` so it can be unit tested.
/// Video frames feed the filtered live preview (`FilteredPreview`); the photo itself is always the unfiltered original.
final class Camera: NSObject, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noCamera, accessDenied, captureFailed
        var errorDescription: String? {
            switch self {
            case .noCamera: "This device has no camera."
            case .accessDenied: "Camera access is off. Turn it on in Settings to take photos."
            case .captureFailed: "The photo couldn't be taken. Try again."
            }
        }
    }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let frames = AVCaptureVideoDataOutput()
    private let framesQueue = DispatchQueue(label: "commonCam.camera.frames")
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Latest preview frame, upright. Read by the preview's draw loop.
    let latestFrame = LatestFrame()
    private let queue = DispatchQueue(label: "commonCam.camera")
    private var format: PhotoFormat = .jpeg
    private var pending: CheckedContinuation<CapturedPhoto, Error>?

    func start() async throws {
        guard Self.backCamera() != nil else { throw Failure.noCamera }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw Failure.accessDenied }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let device = Self.backCamera() else { throw Failure.noCamera }
                    try configure(device)
                    session.startRunning()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    func capture() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let codec: AVVideoCodecType = format == .heic ? .hevc : .jpeg
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                settings.maxPhotoDimensions = output.maxPhotoDimensions
                settings.photoQualityPrioritization = .quality
                if let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
                   let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                pending = continuation
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private static func backCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configure(_ device: AVCaptureDevice) throws {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw Failure.noCamera }
        session.addInput(input)
        session.addOutput(output)
        frames.alwaysDiscardsLateVideoFrames = true
        frames.setSampleBufferDelegate(self, queue: framesQueue)
        if session.canAddOutput(frames) { session.addOutput(frames) }
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
            [weak self] coordinator, _ in
            guard let self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            queue.async { [self] in
                guard let connection = frames.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
        self.rotation = rotation
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            output.maxPhotoDimensions = largest
        }
        output.maxPhotoQualityPrioritization = .quality
        guard let preferred = PhotoFormat.preferred(availableCodecs: output.availablePhotoCodecTypes.map(\.rawValue)) else {
            throw Failure.noCamera
        }
        format = preferred
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        queue.async { [self] in
            let continuation = pending
            pending = nil
            if let data {
                continuation?.resume(returning: CapturedPhoto(data: data, format: format))
            } else {
                continuation?.resume(throwing: error ?? Failure.captureFailed)
            }
        }
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = sampleBuffer.imageBuffer else { return }
        latestFrame.set(CIImage(cvPixelBuffer: pixels))
    }
}

/// Full-screen viewfinder with a shutter. Hands each original to `onCapture`; explains when there is no camera
/// (e.g. the Simulator) instead of failing silently.
struct CameraScreen: View {
    let onCapture: (CapturedPhoto) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera = Camera()
    @State private var filter: FilterDefinition?
    @State private var problem: String?
    @State private var isReady = false
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let problem {
                ContentUnavailableView("Camera unavailable", systemImage: "camera.fill", description: Text(problem))
                    .foregroundStyle(.white)
            } else {
                FilteredPreview(frames: camera.latestFrame, recipe: filter?.recipe()).ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).padding()
                }
                Spacer()
                if problem == nil {
                    FilterPicker(selection: $filter)
                    Button {
                        Task { await shoot() }
                    } label: {
                        Circle().strokeBorder(.white, lineWidth: 5).frame(width: 76, height: 76)
                            .overlay(Circle().fill(.white).padding(9))
                    }
                    .disabled(!isReady || isCapturing)
                    .accessibilityLabel("Take photo")
                    .padding(.bottom, 30)
                }
            }
        }
        .task {
            do {
                try await camera.start()
                isReady = true
            } catch {
                problem = error.localizedDescription
            }
        }
        .onDisappear { camera.stop() }
    }

    private func shoot() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            let original = try await camera.capture()
            onCapture(CapturedPhoto(data: original.data, format: original.format, filterRecipe: filter?.recipe()))
        } catch {
            problem = error.localizedDescription
        }
    }
}
