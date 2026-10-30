import CoreImage
import Foundation

/// Looks that follow faces (Vision landmarks via `FaceDetector`). Every effect is built from soft, wide masks, so a
/// face found a pixel or two differently (preview vs. full-resolution photo) gives a visually identical result.
/// With no faces in view each look still applies its overall grade, so the photo never comes out untouched.
enum FaceLooks {
    /// Warm, softly lit skin with a touch of colour on the cheeks; the rest of the photo only gets the warm grade.
    static let glow = FilterDefinition(
        id: "glow", name: "Glow", version: 1, defaults: ["intensity": 1], usesFaces: true
    ) { image, _, _, faces in
        let extent = image.extent
        let base = image
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5600, y: 10),
            ])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.05, kCIInputContrastKey: 0.95])
        guard !faces.isEmpty else { return base }

        let rects = faces.map { pixelRect($0.bounds, in: extent) }
        let blur = (rects.map(\.width).max() ?? 0) * 0.04
        let smoothed = base.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .cropped(to: extent)
        var lit = base
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: smoothed, kCIInputTimeKey: 0.5])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.45])
        for (face, rect) in zip(faces, rects) {
            for cheek in cheeks(of: face, in: extent, rect: rect) {
                lit = softSpot(at: cheek, radius: rect.width * 0.16, colour: CIColor(red: 1, green: 0.35, blue: 0.45, alpha: 0.38))
                    .cropped(to: extent)
                    .composited(over: lit)
            }
        }
        let mask = union(rects.map { softEllipse(around: $0, scale: CGSize(width: 0.6, height: 0.7), inner: 0.55) }, in: extent)
        return lit.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
    }

    /// Stage lighting: faces stay bright and rich, everything around them falls into a dim, muted dark. With no face
    /// the light falls on the centre of the frame.
    static let spotlight = FilterDefinition(
        id: "spotlight", name: "Spotlight", version: 1, defaults: ["intensity": 1], usesFaces: true
    ) { image, _, _, faces in
        let extent = image.extent
        let lit = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.08, kCIInputContrastKey: 1.06])
        let dark = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.35])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.6])
        let pools: [CIImage]
        if faces.isEmpty {
            let side = min(extent.width, extent.height) * 0.7
            let centre = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
            pools = [softEllipse(around: centre, scale: CGSize(width: 0.6, height: 0.6), inner: 0.4)]
        } else {
            pools = faces.map {
                softEllipse(around: pixelRect($0.bounds, in: extent), scale: CGSize(width: 1.0, height: 1.2), inner: 0.45)
            }
        }
        return lit.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: dark, kCIInputMaskImageKey: union(pools, in: extent),
        ])
    }

    private static func pixelRect(_ normalised: CGRect, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + normalised.minX * extent.width, y: extent.minY + normalised.minY * extent.height,
            width: normalised.width * extent.width, height: normalised.height * extent.height
        )
    }

    /// Cheek centres: below each eye, level with the gap between eyes and mouth. Falls back to the face box.
    private static func cheeks(of face: DetectedFace, in extent: CGRect, rect: CGRect) -> [CGPoint] {
        func pixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + p.y * extent.height)
        }
        guard let left = face.leftEye.map(pixel), let right = face.rightEye.map(pixel), let mouth = face.mouth.map(pixel) else {
            let y = rect.minY + rect.height * 0.38
            return [CGPoint(x: rect.minX + rect.width * 0.25, y: y), CGPoint(x: rect.maxX - rect.width * 0.25, y: y)]
        }
        let y = (min(left.y, right.y) + mouth.y) / 2
        let push = rect.width * 0.05
        let (inner, outer) = left.x < right.x ? (left, right) : (right, left)
        return [CGPoint(x: inner.x - push, y: y), CGPoint(x: outer.x + push, y: y)]
    }

    /// A white ellipse fading to black, `scale` × the rect's size in radius, solid out to `inner` of the radius.
    private static func softEllipse(around rect: CGRect, scale: CGSize, inner: CGFloat) -> CIImage {
        let radius = rect.width * scale.width
        return CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0),
            "inputRadius0": radius * inner,
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ])!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 1, y: rect.height * scale.height / radius)
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }

    private static func softSpot(at point: CGPoint, radius: CGFloat, colour: CIColor) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(cgPoint: point),
            "inputRadius0": 0,
            "inputRadius1": radius,
            "inputColor0": colour,
            "inputColor1": CIColor.clear,
        ])!.outputImage!
    }

    /// The brightest of several masks, on black, limited to `extent`.
    private static func union(_ masks: [CIImage], in extent: CGRect) -> CIImage {
        masks
            .reduce(CIImage(color: .black)) { $1.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) }
            .cropped(to: extent)
    }
}
