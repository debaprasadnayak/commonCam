import CommonCamKit
import SwiftUI

/// The group's shared space: everyone's photos tagged with the contributor's fun name and colour, plus the camera.
struct GalleryView: View {
    let api: APIClient
    let group: EventGroup

    @Environment(UploadCenter.self) private var uploads
    @State private var items: [GalleryItem] = []
    @State private var isCameraOpen = false

    private var queued: [QueuedUpload] {
        uploads.uploads.filter { $0.groupID == group.id }.reversed()
    }

    var body: some View {
        ScrollView {
            if let problem = uploads.problem {
                Text(problem).foregroundStyle(.red).padding()
            }
            if items.isEmpty && queued.isEmpty {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle", description: Text("Tap the camera to add the first one."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(queued) { upload in
                    PendingTile(upload: upload, file: uploads.originalFile(of: upload))
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await uploads.remove(upload) }
                            }
                        }
                }
                ForEach(items) { item in
                    GalleryTile(item: item)
                }
            }
        }
        .navigationTitle("Gallery")
        .toolbar {
            Button("Take photo", systemImage: "camera") { isCameraOpen = true }
        }
        .fullScreenCover(isPresented: $isCameraOpen) {
            CameraScreen { photo in Task { await uploads.enqueue(photo, in: group.id) } }
        }
        .task {
            // Re-listing also renews the short-lived download URLs.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .refreshable { await reload() }
        .onChange(of: uploads.confirmed.count) { Task { await reload() } }
    }

    private func reload() async {
        if let latest = try? await api.gallery(of: group.id) { items = latest }
    }
}

private struct GalleryTile: View {
    let item: GalleryItem

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.downloadUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Label {
                    Text(item.contributor.displayName).lineLimit(1)
                } icon: {
                    Circle().fill(Color(hex: item.contributor.colour)).frame(width: 10, height: 10)
                }
                .font(.caption2)
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Photo by \(item.contributor.displayName)")
    }
}

/// A shot still in the upload queue, shown from the local original with a badge until the server confirms it.
private struct PendingTile: View {
    let upload: QueuedUpload
    let file: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill().opacity(0.6)
                }
            }
            .task(id: file) {
                guard let image = UIImage(contentsOfFile: file.path()) else { return }
                let scale = 300 / max(image.size.width, image.size.height, 1)
                thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                Label(upload.failureMessage ?? "Pending", systemImage: upload.isPending ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(upload.isPending ? Color.primary : Color.red)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(upload.isPending ? "Photo waiting to upload" : "Photo not shared: \(upload.failureMessage ?? "")")
    }
}
