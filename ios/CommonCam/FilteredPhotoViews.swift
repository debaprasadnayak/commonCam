import CommonCamKit
import ImageIO
import Photos
import SwiftUI

/// Decodes an original (HEIC/JPEG), upright and downsampled to `maxPixelSize`, then applies `recipe`.
/// `nil` recipe = the original. Throws `FilterRenderer.Failure` when this build can't render the recipe.
private func render(_ original: Data, with recipe: FilterRecipe?, maxPixelSize: Int) throws -> UIImage {
    guard let source = CGImageSourceCreateWithData(original as CFData, nil),
          let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          ] as CFDictionary)
    else { throw FilterRenderer.Failure.unreadableImage }
    let image = try FilterRenderer.apply(recipe, to: CIImage(cgImage: decoded))
    guard let output = FilterRenderer.context.createCGImage(image, from: image.extent) else {
        throw FilterRenderer.Failure.unreadableImage
    }
    return UIImage(cgImage: output)
}

private func download(_ url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
}

/// A gallery tile's picture: the filtered version when the item has a recipe this build can render, else the original.
struct FilteredThumbnail: View {
    let item: GalleryItem
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: item.id) {
            guard let original = try? await download(item.downloadUrl) else { return }
            let recipe = item.filterRecipe
            // Off the main actor: face-based looks run Vision while rendering.
            image = await Task.detached {
                (try? render(original, with: recipe, maxPixelSize: 400)) ?? (try? render(original, with: nil, maxPixelSize: 400))
            }.value
        }
    }
}

/// One photo full screen: switch between the filtered version and the untouched original, and save either.
struct ItemDetailView: View {
    enum Version: String, CaseIterable, Identifiable {
        case filtered = "Filtered", original = "Original"
        var id: Self { self }
    }

    let item: GalleryItem
    @State private var original: Data?
    @State private var filtered: UIImage?
    @State private var plain: UIImage?
    @State private var version: Version = .filtered
    @State private var cannotRenderFilter = false
    @State private var status: String?
    @State private var isSaving = false

    private var showsFiltered: Bool { item.filterRecipe != nil && !cannotRenderFilter && version == .filtered }

    var body: some View {
        VStack {
            if let image = showsFiltered ? filtered : plain {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .pendingReviewBlur(item.isHidden)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if item.filterRecipe != nil {
                if cannotRenderFilter {
                    Text("This photo's filter needs a newer version of commonCam, so the original is shown.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Picker("Version", selection: $version) {
                        ForEach(Version.allCases) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            if let status {
                Text(status).font(.footnote)
            }
        }
        .padding()
        .navigationTitle(item.contributor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(showsFiltered ? "Save filtered" : "Save original", systemImage: "square.and.arrow.down") {
                Task { await save() }
            }
            .disabled(original == nil || isSaving)
        }
        .task(id: item.id) { await load() }
    }

    private func load() async {
        do {
            let data = try await download(item.downloadUrl)
            original = data
            let recipe = item.filterRecipe
            plain = try await Task.detached { try render(data, with: nil, maxPixelSize: 2048) }.value
            do {
                filtered = try await Task.detached { try render(data, with: recipe, maxPixelSize: 2048) }.value
            } catch is FilterRenderer.Failure {
                cannotRenderFilter = true
            }
        } catch {
            status = "Couldn't load the photo."
        }
    }

    /// Saves the untouched original bytes, or a full-resolution render of the recipe over them.
    private func save() async {
        guard let original else { return }
        isSaving = true
        defer { isSaving = false }
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            status = "Allow commonCam to add photos in Settings to save."
            return
        }
        do {
            let recipe = showsFiltered ? item.filterRecipe : nil
            let data = recipe == nil ? original : try await Task.detached { try FilterRenderer.renderedJPEG(of: original, with: recipe) }.value
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            status = showsFiltered ? "Saved the filtered photo." : "Saved the original."
        } catch {
            status = "Couldn't save the photo."
        }
    }
}
