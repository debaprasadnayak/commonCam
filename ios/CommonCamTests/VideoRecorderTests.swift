@preconcurrency import AVFoundation
@testable import CommonCam
import CommonCamKit
import XCTest

/// Drives the real AVAssetWriter pipeline with synthetic camera frames (the Simulator has no camera).
final class VideoRecorderTests: XCTestCase {
    private let queue = DispatchQueue(label: "VideoRecorderTests.frames")

    func testAClipFinishesByItselfAtSixtySecondsAsAnHEVCMovie() async throws {
        let recorder = VideoRecorder()
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        let finished = expectation(description: "clip finished without a stop")
        nonisolated(unsafe) var result: Result<CapturedVideo, Error>?
        queue.sync {
            recorder.start(file: file, videoSettings: nil, audioSettings: nil, progress: { _ in }) {
                result = $0
                finished.fulfill()
            }
        }

        // Two frames a second for 70 s of camera time, starting at an arbitrary clock value.
        for index in 0...140 {
            let sample = try Self.frame(at: 500 + Double(index) / 2)
            queue.sync { recorder.appendVideo(sample) }
            if !recorder.isRecording { break }
            try await Task.sleep(for: .milliseconds(5)) // let the real-time encoder keep up
        }

        await fulfillment(of: [finished], timeout: 30)
        let clip = try XCTUnwrap(result).get()
        defer { try? FileManager.default.removeItem(at: clip.file) }
        let asset = AVURLAsset(url: clip.file)
        let duration = try await asset.load(.duration).seconds
        XCTAssertLessThanOrEqual(duration, 60)
        XCTAssertGreaterThan(duration, 59)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let codec = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        XCTAssertEqual(codec, kCMVideoCodecType_HEVC)
    }

    private static func frame(at seconds: Double) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        let format = try CMVideoFormatDescription(imageBuffer: buffer)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        return try CMSampleBuffer(imageBuffer: buffer, formatDescription: format, sampleTiming: timing)
    }
}
