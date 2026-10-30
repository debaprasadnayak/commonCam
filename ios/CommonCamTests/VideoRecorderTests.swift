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
            recorder.start(file: file, videoSettings: nil, audioSettings: nil, recipe: nil, progress: { _ in }) {
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

    // Pure red camera frames: the mono "Ink" look must turn them grey in the file; with the filter off they stay red.
    func testTheChosenFilterIsBakedIntoEveryFrame() async throws {
        let ink = try XCTUnwrap(FilterCatalog.definition(id: "ink")).recipe()
        let (red, green, blue) = try await recordRedClip(recipe: ink)
        XCTAssertEqual(red, green, accuracy: 0.08)
        XCTAssertEqual(green, blue, accuracy: 0.08)
        XCTAssertGreaterThan(green, 0.15, "red turned to grey, not black")
    }

    func testWithTheFilterOffFramesAreRecordedAsShot() async throws {
        let (red, green, blue) = try await recordRedClip(recipe: nil)
        XCTAssertGreaterThan(red, 0.8)
        XCTAssertLessThan(green, 0.2)
        XCTAssertLessThan(blue, 0.2)
    }

    /// Records 3 s of red frames with `recipe`, then decodes a frame from the middle and the end of the movie.
    /// Returns the mean colour (0…1) of the middle frame, after checking the last frame matches it.
    private func recordRedClip(recipe: FilterRecipe?) async throws -> (Double, Double, Double) {
        let recorder = VideoRecorder()
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        let finished = expectation(description: "clip finished")
        nonisolated(unsafe) var result: Result<CapturedVideo, Error>?
        queue.sync {
            recorder.start(file: file, videoSettings: nil, audioSettings: nil, recipe: recipe, progress: { _ in }) {
                result = $0
                finished.fulfill()
            }
        }
        for index in 0...30 {
            let sample = try Self.frame(at: 100 + Double(index) / 10, bgra: (0, 0, 255))
            queue.sync { recorder.appendVideo(sample) }
            try await Task.sleep(for: .milliseconds(5))
        }
        queue.sync { recorder.stop() }
        await fulfillment(of: [finished], timeout: 30)
        let clip = try XCTUnwrap(result).get()
        defer { try? FileManager.default.removeItem(at: clip.file) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.file))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let middle = try Self.meanColour(of: await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image)
        let last = try Self.meanColour(of: await generator.image(at: CMTime(seconds: 2.9, preferredTimescale: 600)).image)
        XCTAssertEqual(middle.0, last.0, accuracy: 0.05)
        XCTAssertEqual(middle.1, last.1, accuracy: 0.05)
        XCTAssertEqual(middle.2, last.2, accuracy: 0.05)
        return middle
    }

    private static func meanColour(of image: CGImage) throws -> (Double, Double, Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private static func frame(at seconds: Double, bgra: (UInt8, UInt8, UInt8)? = nil) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        if let (b, g, r) = bgra {
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<64 {
                    let offset = y * rowBytes + x * 4
                    (base[offset], base[offset + 1], base[offset + 2], base[offset + 3]) = (b, g, r, 255)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        let format = try CMVideoFormatDescription(imageBuffer: buffer)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        return try CMSampleBuffer(imageBuffer: buffer, formatDescription: format, sampleTiming: timing)
    }
}
