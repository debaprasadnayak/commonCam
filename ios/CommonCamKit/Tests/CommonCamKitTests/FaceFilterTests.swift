import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CommonCamKit

private let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures")

/// A generated (drawn, not photographed) 160×160 portrait that Vision recognises as one face.
private let face: CIImage = CIImage(contentsOf: fixtures.appending(path: "face.png"))!

private func pixels(_ image: CIImage) -> [UInt8] {
    let extent = image.extent
    var out = [UInt8](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
    FilterRenderer.context.render(
        image, toBitmap: &out, rowBytes: Int(extent.width) * 4, bounds: extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
    return out
}

private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
}

/// Mean brightness (0…255) of a square around a point given in 0…1 image coordinates (origin bottom-left).
private func brightness(_ image: CIImage, at point: CGPoint, size: Int = 8) -> Double {
    let extent = image.extent
    let rect = CGRect(
        x: extent.minX + point.x * extent.width - CGFloat(size) / 2,
        y: extent.minY + point.y * extent.height - CGFloat(size) / 2,
        width: CGFloat(size), height: CGFloat(size)
    )
    let values = pixels(image.cropped(to: rect))
    let rgb = values.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
    return rgb.reduce(0, +) / Double(rgb.count)
}

private func png(_ rgba: [UInt8], width: Int, height: Int) -> Data {
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func rgba(fromPNG data: Data) throws -> [UInt8] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &out, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return out
}

private let faceFilters = FilterCatalog.all.filter(\.usesFaces)

struct FaceDetectionTests {
    @Test func findsTheOneFaceInThePortraitWithItsEyesAndMouth() throws {
        let faces = FaceDetector.detect(in: face)

        let found = try #require(faces.first)
        #expect(faces.count == 1)
        #expect(abs(found.bounds.midX - 0.5) < 0.1 && abs(found.bounds.midY - 0.5) < 0.15)
        let leftEye = try #require(found.leftEye), rightEye = try #require(found.rightEye), mouth = try #require(found.mouth)
        #expect(abs(leftEye.y - rightEye.y) < 0.05)
        #expect(mouth.y < leftEye.y && mouth.y < rightEye.y)
    }

    @Test func findsNoFacesInAnAbstractImage() {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 64),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))

        #expect(FaceDetector.detect(in: gradient).isEmpty)
    }

    @Test func detectsTheSameFaceEveryTime() {
        #expect(FaceDetector.detect(in: face) == FaceDetector.detect(in: face))
    }
}

struct FaceFilterTests {
    @Test func theCatalogueOffersTenToTwelveLooksIncludingFaceBasedOnes() {
        #expect((10...12).contains(FilterCatalog.all.count))
        #expect(!faceFilters.isEmpty)
    }

    /// The recipe stores no face positions: rendering it from the original finds the faces itself, so the result
    /// matches the stored expected output (Tests/Fixtures/filters/<id>-v<version>-face.png) within 3/255.
    @Test(arguments: faceFilters)
    func rendersThePortraitFromTheRecipeAloneToItsStoredExpectedOutput(_ filter: FilterDefinition) throws {
        let rendered = pixels(try FilterRenderer.apply(filter.recipe(), to: face))
        let golden = fixtures.appending(path: "filters/\(filter.id)-v\(filter.version)-face.png")
        let width = Int(face.extent.width), height = Int(face.extent.height)

        if ProcessInfo.processInfo.environment["RECORD_FILTER_GOLDENS"] == "1" {
            try png(rendered, width: width, height: height).write(to: golden)
            Issue.record("Recorded \(golden.lastPathComponent); re-run without RECORD_FILTER_GOLDENS")
            return
        }
        let expected = try rgba(fromPNG: try Data(contentsOf: golden))
        #expect(expected.count == rendered.count)
        #expect(maxDifference(rendered, expected) <= 3)
    }

    @Test(arguments: faceFilters)
    func detectingFacesAtRenderTimeMatchesPassingTheLivePreviewsFaces(_ filter: FilterDefinition) throws {
        let fromRecipe = try FilterRenderer.apply(filter.recipe(), to: face)
        let withFaces = try FilterRenderer.apply(filter.recipe(), to: face, faces: FaceDetector.detect(in: face))

        #expect(pixels(fromRecipe) == pixels(withFaces))
    }

    @Test(arguments: faceFilters)
    func theLookFollowsTheFace(_ filter: FilterDefinition) throws {
        let withFace = try FilterRenderer.apply(filter.recipe(), to: face)
        let withoutFace = try FilterRenderer.apply(filter.recipe(), to: face, faces: [])

        #expect(maxDifference(pixels(withFace), pixels(withoutFace)) > 10)
    }

    @Test func glowBrightensTheFaceMoreThanTheBackground() throws {
        let glow = try FilterRenderer.apply(FilterRecipe(id: "glow", version: 1), to: face)
        let cheek = CGPoint(x: 0.42, y: 0.5), background = CGPoint(x: 0.08, y: 0.9)

        let faceGain = brightness(glow, at: cheek) - brightness(face, at: cheek)
        let backgroundGain = brightness(glow, at: background) - brightness(face, at: background)
        #expect(faceGain > backgroundGain + 5)
    }

    @Test func spotlightKeepsTheFaceLitAndDarkensAroundIt() throws {
        let spotlight = try FilterRenderer.apply(FilterRecipe(id: "spotlight", version: 1), to: face)
        let cheek = CGPoint(x: 0.42, y: 0.5), corner = CGPoint(x: 0.06, y: 0.94)

        #expect(abs(brightness(spotlight, at: cheek) - brightness(face, at: cheek)) < 20)
        #expect(brightness(spotlight, at: corner) < brightness(face, at: corner) - 40)
    }
}
