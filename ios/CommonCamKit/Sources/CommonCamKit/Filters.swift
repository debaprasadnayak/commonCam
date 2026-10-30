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
    let apply: @Sendable (_ image: CIImage, _ params: [String: Double], _ version: Int) -> CIImage

    public var description: String { id }

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
    ]

    public static func definition(id: String) -> FilterDefinition? {
        all.first { $0.id == id }
    }
}
