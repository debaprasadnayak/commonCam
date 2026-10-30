import CoreImage
import Foundation

/// One look in the camera. `apply` gets the photo and the recipe's params merged over `defaults`, and must be
/// a pure function of those (no randomness, no clock) so a recipe renders the same everywhere, every time.
/// To add a filter (#7), append a definition to `FilterCatalog.all`. To change an existing look, bump its
/// `version` and keep rendering older versions as before, so photos already taken don't change.
public struct FilterDefinition: Sendable, Identifiable, CustomStringConvertible {
    public let id: String
    public let name: String
    public let version: Int
    public let defaults: [String: Double]
    /// Face-based looks get the faces in the image (see `FaceDetector`); everything else gets an empty list.
    public let usesFaces: Bool
    let apply: @Sendable (_ image: CIImage, _ params: [String: Double], _ version: Int, _ faces: [DetectedFace]) -> CIImage

    public var description: String { id }

    init(
        id: String, name: String, version: Int, defaults: [String: Double],
        apply: @escaping @Sendable (_ image: CIImage, _ params: [String: Double], _ version: Int) -> CIImage
    ) {
        self.init(id: id, name: name, version: version, defaults: defaults, usesFaces: false) { image, params, version, _ in
            apply(image, params, version)
        }
    }

    init(
        id: String, name: String, version: Int, defaults: [String: Double], usesFaces: Bool,
        apply: @escaping @Sendable (_ image: CIImage, _ params: [String: Double], _ version: Int, _ faces: [DetectedFace]) -> CIImage
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.defaults = defaults
        self.usesFaces = usesFaces
        self.apply = apply
    }

    /// A recipe for this look at its current version; `params` override the defaults.
    public func recipe(params: [String: Double] = [:]) -> FilterRecipe {
        FilterRecipe(id: id, version: version, params: defaults.merging(params) { $1 })
    }
}

public enum FilterCatalog {
    /// In the order the camera offers them. Every filter also takes `intensity` (0 = as shot, 1 = full look).
    public static let all: [FilterDefinition] = [
        FilterDefinition(id: "golden-hour", name: "Golden Hour", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            image
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 4600, y: 8),
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1, kCIInputContrastKey: 1.05])
        },
        FilterDefinition(id: "ink", name: "Ink", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.08])
        },
        FilterDefinition(id: "faded", name: "Faded", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            let extent = image.extent
            return image
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.35])
                // Lift the blacks and soften the whites, like old print paper.
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.85, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.8, w: 0),
                    "inputBiasVector": CIVector(x: 0.08, y: 0.07, z: 0.08, w: 0),
                ])
                .applyingFilter("CIVignetteEffect", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputRadiusKey: hypot(extent.width, extent.height) * 0.45,
                    kCIInputIntensityKey: 0.6,
                ])
        },
        FilterDefinition(id: "film-grain", name: "Film Grain", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            let extent = image.extent
            // CIRandomGenerator is a fixed pattern, so the grain is the same on every render. Scaling it with the
            // image keeps the grain the same relative size in the live preview and in the full-resolution photo.
            let scale = max(1, max(extent.width, extent.height) / 1200)
            let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: extent)
                // Its alpha is random too; drop it so the colour matrix below doesn't un-premultiply into spikes.
                .settingAlphaOne(in: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.44, y: 0.44, z: 0.44, w: 0),
                ])
            // Mid-grey grain soft-lit over the photo (0.5 leaves a pixel alone). Blended in sRGB rather than the
            // linear working space so shadows get the same grain as highlights, like film.
            let base = image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.1])
                .applyingFilter("CILinearToSRGBToneCurve")
            return grain
                .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: base])
                .applyingFilter("CISRGBToneCurveToLinear")
        },
        FilterDefinition(id: "pop", name: "Pop", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.9])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputBrightnessKey: 0.02])
        },
        FilterDefinition(id: "dusk", name: "Dusk", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            // Split tone from one matrix: blue gets a bias and less gain (bluer shadows), red more gain (warmer highlights).
            image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.06])
                .inSRGB {
                    $0.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 1.14, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.97, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.78, w: 0),
                        "inputBiasVector": CIVector(x: -0.06, y: 0.02, z: 0.14, w: 0),
                    ])
                }
        },
        FilterDefinition(id: "sorbet", name: "Sorbet", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": SorbetLUT.dimension,
                "inputCubeData": SorbetLUT.data,
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        },
        FilterDefinition(id: "silver", name: "Silver", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            // Bleach-bypass style: a grey copy overlaid on the colour one, for hard contrast and muted colour.
            image.inSRGB { photo in
                photo
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                    .applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: photo])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.55, kCIInputBrightnessKey: -0.02])
            }
        },
        FilterDefinition(id: "haze", name: "Haze", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            let extent = image.extent
            // Radius relative to the image, so the preview and the full-resolution photo bloom alike.
            return image
                .clampedToExtent()
                .applyingFilter("CIBloom", parameters: [
                    kCIInputRadiusKey: max(extent.width, extent.height) * 0.02,
                    kCIInputIntensityKey: 0.7,
                ])
                .cropped(to: extent)
                .inSRGB {
                    $0.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.88, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.9, w: 0),
                        "inputBiasVector": CIVector(x: 0.1, y: 0.08, z: 0.1, w: 0),
                    ])
                }
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.9])
        },
        FilterDefinition(id: "retro", name: "Retro", version: 1, defaults: ["intensity": 1]) { image, _, _ in
            // Faded print: flattened ends of the tone curve, less blue, a warm cast.
            image.inSRGB {
                $0
                    .applyingFilter("CIToneCurve", parameters: [
                        "inputPoint0": CIVector(x: 0, y: 0.1),
                        "inputPoint1": CIVector(x: 0.25, y: 0.24),
                        "inputPoint2": CIVector(x: 0.5, y: 0.52),
                        "inputPoint3": CIVector(x: 0.75, y: 0.79),
                        "inputPoint4": CIVector(x: 1, y: 0.93),
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 1.04, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.97, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.8, w: 0),
                        "inputBiasVector": CIVector(x: 0.02, y: 0.01, z: 0.03, w: 0),
                    ])
            }
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.88])
        },
        FaceLooks.glow,
        FaceLooks.spotlight,
    ]

    public static func definition(id: String) -> FilterDefinition? {
        all.first { $0.id == id }
    }
}

extension CIImage {
    /// Runs `body` on gamma-encoded sRGB values instead of Core Image's linear working space, so colour matrices and
    /// curves act on tones the way the eye sees them (a shadow lift stays a shadow lift).
    func inSRGB(_ body: (CIImage) -> CIImage) -> CIImage {
        body(applyingFilter("CILinearToSRGBToneCurve")).applyingFilter("CISRGBToneCurveToLinear")
    }
}

/// Sorbet's 3D LUT, computed (not hand-painted) so it is exact and reviewable: pastel, high-key, mint shadows and
/// peach highlights. Defined over sRGB values.
enum SorbetLUT {
    static let dimension = 17

    static let data: Data = {
        let n = dimension
        var cube = [Float]()
        cube.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rgb = [r, g, b].map { Double($0) / Double(n - 1) }
                    let luma = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
                    // Less saturated, then lifted and compressed toward the top of the range.
                    var out = rgb.map { luma + ($0 - luma) * 0.7 }.map { 0.14 + $0 * 0.82 }
                    out[0] += 0.05 * luma - 0.02 * (1 - luma)
                    out[1] += 0.04 * (1 - luma)
                    out[2] += 0.03 * (1 - luma) - 0.04 * luma
                    cube += out.map { Float(min(max($0, 0), 1)) } + [1]
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}
