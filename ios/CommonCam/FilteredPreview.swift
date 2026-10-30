import CommonCamKit
import CoreImage
import MetalKit
import SwiftUI

/// The most recent camera frame, handed from the capture queue to the preview's draw loop.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CIImage?

    func set(_ frame: CIImage) {
        lock.withLock { self.frame = frame }
    }

    func get() -> CIImage? {
        lock.withLock { frame }
    }
}

/// Finds faces in preview frames for the face-based looks, off the draw loop and one frame at a time: the preview
/// keeps drawing at full rate with the most recent faces while the next detection runs.
final class FaceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "commonCam.preview.faces", qos: .userInitiated)
    private var faces: [DetectedFace] = []
    private var isDetecting = false

    /// The latest faces found, and starts looking in `frame` unless a detection is already running.
    func faces(updatingFrom frame: CIImage) -> [DetectedFace] {
        lock.withLock {
            if !isDetecting {
                isDetecting = true
                queue.async { [self] in
                    let found = FaceDetector.detect(in: frame)
                    lock.withLock {
                        faces = found
                        isDetecting = false
                    }
                }
            }
            return faces
        }
    }
}

/// Live viewfinder with the chosen filter applied on the GPU: Core Image renders straight into a Metal drawable
/// on the display link, at the camera's frame rate, using the same `FilterRenderer` as the gallery and saving.
struct FilteredPreview: UIViewRepresentable {
    let frames: LatestFrame
    let recipe: FilterRecipe?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.recipe = recipe
    }

    func makeCoordinator() -> Renderer {
        Renderer(frames: frames)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        let frames: LatestFrame
        var recipe: FilterRecipe?
        private let faceTracker = FaceTracker()
        private let queue: MTLCommandQueue?
        private let context: CIContext?

        init(frames: LatestFrame) {
            self.frames = frames
            queue = device?.makeCommandQueue()
            context = queue.map {
                CIContext(mtlCommandQueue: $0, options: [
                    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                    .cacheIntermediates: false,
                ])
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let frame = frames.get(), let context, let drawable = view.currentDrawable,
                  let buffer = queue?.makeCommandBuffer() else { return }
            let usesFaces = recipe.flatMap { FilterCatalog.definition(id: $0.id) }?.usesFaces == true
            let faces = usesFaces ? faceTracker.faces(updatingFrom: frame) : nil
            let filtered = (try? FilterRenderer.apply(recipe, to: frame, faces: faces)) ?? frame
            // Aspect-fill the drawable, centred.
            let size = view.drawableSize
            let scale = max(size.width / frame.extent.width, size.height / frame.extent.height)
            let scaled = filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let image = scaled.transformed(by: CGAffineTransform(
                translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY
            ))
            let destination = CIRenderDestination(
                width: Int(size.width), height: Int(size.height), pixelFormat: view.colorPixelFormat,
                commandBuffer: buffer
            ) { drawable.texture }
            destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            _ = try? context.startTask(toRender: image, to: destination)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

/// "None" plus every look in `FilterCatalog`, as a horizontal strip above the shutter.
struct FilterPicker: View {
    @Binding var selection: FilterDefinition?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip("None", selected: selection == nil) { selection = nil }
                ForEach(FilterCatalog.all) { filter in
                    chip(filter.name, selected: selection?.id == filter.id) { selection = filter }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(selected ? .bold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? Color.white : Color.black.opacity(0.4), in: Capsule())
            .foregroundStyle(selected ? Color.black : Color.white)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
