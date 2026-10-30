import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CommonCamKit

/// A fixed, hand-defined input: red ramps left→right, green top→bottom, blue the reverse diagonal.
private let fixtureWidth = 48
private let fixtureHeight = 32
private let fixture: CIImage = {
    var bytes = [UInt8](repeating: 255, count: fixtureWidth * fixtureHeight * 4)
    for y in 0..<fixtureHeight {
        for x in 0..<fixtureWidth {
            let i = (y * fixtureWidth + x) * 4
            bytes[i] = UInt8(x * 255 / (fixtureWidth - 1))
            bytes[i + 1] = UInt8(y * 255 / (fixtureHeight - 1))
            bytes[i + 2] = UInt8(255 - (x + y) * 255 / (fixtureWidth + fixtureHeight - 2))
        }
    }
    return CIImage(
        bitmapData: Data(bytes), bytesPerRow: fixtureWidth * 4,
        size: CGSize(width: fixtureWidth, height: fixtureHeight), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
}()

private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
        .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
}

/// sRGB RGBA8 pixels, as they would be saved.
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

private let goldens = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/filters")

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

struct FilterRenderingTests {
    /// Each filter at its defaults, rendered from the fixed fixture, must match the stored expected output
    /// (Tests/Fixtures/filters/<id>-v<version>.png) within 3/255 per channel, so CPU/GPU rounding differences pass
    /// but any change to a look fails. After an intentional change, bump the filter's version (old recipes keep
    /// their look) and re-record with `RECORD_FILTER_GOLDENS=1 swift test`.
    @Test(arguments: FilterCatalog.all)
    func rendersEachFilterToItsStoredExpectedOutput(_ filter: FilterDefinition) throws {
        let rendered = pixels(try FilterRenderer.apply(filter.recipe(), to: fixture))
        let golden = goldens.appending(path: "\(filter.id)-v\(filter.version).png")

        if ProcessInfo.processInfo.environment["RECORD_FILTER_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
            try png(rendered, width: fixtureWidth, height: fixtureHeight).write(to: golden)
            Issue.record("Recorded \(golden.lastPathComponent); re-run without RECORD_FILTER_GOLDENS")
            return
        }
        let expected = try rgba(fromPNG: try Data(contentsOf: golden))
        #expect(expected.count == rendered.count)
        #expect(maxDifference(rendered, expected) <= 3)
        #expect(maxDifference(rendered, pixels(fixture)) > 10, "the filter should visibly change the photo")
    }

    @Test(arguments: FilterCatalog.all)
    func rendersTheSameRecipeIdenticallyEveryTime(_ filter: FilterDefinition) throws {
        let recipe = filter.recipe()
        #expect(pixels(try FilterRenderer.apply(recipe, to: fixture)) == pixels(try FilterRenderer.apply(recipe, to: fixture)))
    }

    @Test(arguments: FilterCatalog.all)
    func atZeroIntensityLeavesThePhotoAsShot(_ filter: FilterDefinition) throws {
        let rendered = try FilterRenderer.apply(filter.recipe(params: ["intensity": 0]), to: fixture)

        #expect(rendered.extent == fixture.extent)
        #expect(maxDifference(pixels(rendered), pixels(fixture)) <= 1)
    }

    @Test func withoutARecipeShowsTheOriginal() throws {
        #expect(pixels(try FilterRenderer.apply(nil, to: fixture)) == pixels(fixture))
    }

    @Test func inkTurnsColoursToGreys() throws {
        let red = pixels(try FilterRenderer.apply(FilterRecipe(id: "ink", version: 1), to: solid(0.9, 0.1, 0.1)))

        #expect(abs(Int(red[0]) - Int(red[1])) <= 1 && abs(Int(red[1]) - Int(red[2])) <= 1)
    }

    @Test func goldenHourWarmsANeutralGrey() throws {
        let grey = pixels(try FilterRenderer.apply(FilterRecipe(id: "golden-hour", version: 1), to: solid(0.5, 0.5, 0.5)))

        #expect(Int(grey[0]) - Int(grey[2]) > 15)
    }

    @Test func refusesAFilterThisAppDoesNotKnow() {
        #expect(throws: FilterRenderer.Failure.unknownFilter("sparkle")) {
            try FilterRenderer.apply(FilterRecipe(id: "sparkle", version: 1), to: fixture)
        }
    }

    @Test func refusesANewerVersionOfAFilterThanThisAppHas() throws {
        let ink = try #require(FilterCatalog.definition(id: "ink"))

        #expect(throws: FilterRenderer.Failure.unsupportedVersion("ink", ink.version + 1)) {
            try FilterRenderer.apply(FilterRecipe(id: "ink", version: ink.version + 1), to: fixture)
        }
    }

    @Test func catalogueHasUniqueIdsAndStartsWithAHandfulOfLooks() {
        let ids = FilterCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count >= 5)
    }

    @Test func savesTheFilteredVersionAsAJPEGTheSameSizeAsTheOriginal() throws {
        let original = png(pixels(fixture), width: fixtureWidth, height: fixtureHeight)

        let saved = try FilterRenderer.renderedJPEG(of: original, with: FilterRecipe(id: "ink", version: 1))

        let source = try #require(CGImageSourceCreateWithData(saved as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == fixtureWidth && image.height == fixtureHeight)
    }
}
