import CoreImage
import Foundation

/// Renders a `FilterRecipe` over an original. Used for the live camera preview, gallery display and saving the
/// filtered version, so all three show the same look.
public enum FilterRenderer {
    public enum Failure: Error, Equatable {
        /// The recipe names a filter this build doesn't have (e.g. shot on a newer app version).
        case unknownFilter(String)
        case unsupportedVersion(String, Int)
        case unreadableImage
    }

    /// Shared, thread-safe context with fixed colour handling, so output doesn't depend on the device's display.
    public static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])

    /// The filtered image, same extent as `image`. `nil` recipe = the original.
    /// Face-based looks use `faces` when given (the live preview tracks them on its own schedule), otherwise they
    /// find the faces in `image` now, so a stored recipe needs nothing but the original.
    public static func apply(_ recipe: FilterRecipe?, to image: CIImage, faces: [DetectedFace]? = nil) throws -> CIImage {
        guard let recipe else { return image }
        guard let filter = FilterCatalog.definition(id: recipe.id) else { throw Failure.unknownFilter(recipe.id) }
        guard (1...filter.version).contains(recipe.version) else {
            throw Failure.unsupportedVersion(recipe.id, recipe.version)
        }
        let params = filter.defaults.merging(recipe.params) { $1 }
        let intensity = min(max(params["intensity"] ?? 1, 0), 1)
        let faces = filter.usesFaces ? faces ?? FaceDetector.detect(in: image) : []
        let look = filter.apply(image, params, recipe.version, faces).cropped(to: image.extent)
        return image
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: look, kCIInputTimeKey: intensity])
            .cropped(to: image.extent)
    }

    /// The filtered version of an encoded original (HEIC/JPEG), upright, as a full-resolution JPEG for saving.
    public static func renderedJPEG(of original: Data, with recipe: FilterRecipe?) throws -> Data {
        guard let image = CIImage(data: original, options: [.applyOrientationProperty: true]) else {
            throw Failure.unreadableImage
        }
        let rendered = try apply(recipe, to: image)
        guard let jpeg = context.jpegRepresentation(
            of: rendered, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]
        ) else { throw Failure.unreadableImage }
        return jpeg
    }
}
