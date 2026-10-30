import CoreImage
import Foundation
import Vision

/// One face found in a photo or preview frame. All positions are in 0…1 image coordinates with the origin at the
/// bottom left (Core Image and Vision convention), so they apply at any resolution: a face found in a downsampled
/// preview frame lines up with the full-resolution photo.
public struct DetectedFace: Equatable, Sendable {
    public let bounds: CGRect
    public let leftEye: CGPoint?
    public let rightEye: CGPoint?
    public let mouth: CGPoint?

    public init(bounds: CGRect, leftEye: CGPoint? = nil, rightEye: CGPoint? = nil, mouth: CGPoint? = nil) {
        self.bounds = bounds
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.mouth = mouth
    }
}

/// Vision face landmarks for face-based filters. Recipes never store face positions: they are found again from the
/// original whenever it is rendered, so a photo always renders from just its original and recipe.
public enum FaceDetector {
    /// Faces in `image` (upright), ordered left to right then bottom to top. Empty when there are none or Vision fails.
    public static func detect(in image: CIImage) -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()
        // Pinned so an OS update can't silently move where an old photo's effect lands.
        request.revision = VNDetectFaceLandmarksRequestRevision3
        do {
            try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? [])
            .map { observation in
                let box = observation.boundingBox
                func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
                    guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
                    let x = points.map(\.x).reduce(0, +) / CGFloat(points.count)
                    let y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
                    return CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
                }
                let landmarks = observation.landmarks
                return DetectedFace(
                    bounds: box,
                    leftEye: centre(landmarks?.leftEye),
                    rightEye: centre(landmarks?.rightEye),
                    mouth: centre(landmarks?.outerLips)
                )
            }
            .sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
    }
}
