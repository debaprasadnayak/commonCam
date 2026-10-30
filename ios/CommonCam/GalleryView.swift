import CommonCamKit
import SwiftUI

/// The group's shared space: everyone's photos tagged with the contributor's fun name and colour, plus the camera.
struct GalleryView: View {
    let api: APIClient
    let group: EventGroup

    @State private var items: [GalleryItem] = []
    @State private var isCameraOpen = false
    @State private var uploading = 0
    @State private var errorMessage: String?
    @State private var saveProgress: BulkSaveProgress?
    @State private var saveNotice: String?

    var body: some View {
        ScrollView {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding()
            }
            if let saveProgress {
                ProgressView("Saving to Photos…", value: Double(saveProgress.done), total: Double(max(saveProgress.total, 1)))
                    .padding()
            }
            if let saveNotice {
                Text(saveNotice).foregroundStyle(.secondary).padding()
            }
            if uploading > 0 {
                Label("Uploading \(uploading) photo\(uploading == 1 ? "" : "s")…", systemImage: "arrow.up.circle")
                    .padding(.top)
            }
            if items.isEmpty && uploading == 0 {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle", description: Text("Tap the camera to add the first one."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(items) { item in
                    GalleryTile(item: item)
                        .contextMenu {
                            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                                Task { await save([item]) }
                            }
                            .disabled(saveProgress != nil)
                        }
                }
            }
        }
        .navigationTitle("Gallery")
        .toolbar {
            Button("Save all to Photos", systemImage: "square.and.arrow.down.on.square") {
                Task { await saveAll() }
            }
            .disabled(items.isEmpty || saveProgress != nil)
            Button("Take photo", systemImage: "camera") { isCameraOpen = true }
        }
        .fullScreenCover(isPresented: $isCameraOpen) {
            CameraScreen { photo in Task { await share(photo) } }
        }
        .task {
            // Re-listing also renews the short-lived download URLs.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        if let latest = try? await api.gallery(of: group.id) { items = latest }
    }

    private func saveAll() async {
        await reload() // fresh download URLs: they expire after 15 minutes
        await save(items)
    }

    private func save(_ toSave: [GalleryItem]) async {
        saveNotice = nil
        saveProgress = BulkSaveProgress(done: 0, total: toSave.count)
        let report = await PhotoSaver.live.save(toSave) { progress in
            await MainActor.run { saveProgress = progress }
        }
        saveProgress = nil
        saveNotice = if report.accessDenied {
            PhotosAccessMessage.denied
        } else if report.failed.isEmpty {
            "Saved \(report.saved.count) photo\(report.saved.count == 1 ? "" : "s") to Photos."
        } else {
            "Saved \(report.saved.count) of \(toSave.count) to Photos; \(report.failed.count) couldn't be saved. Try those again."
        }
    }

    private func share(_ photo: CapturedPhoto) async {
        uploading += 1
        defer { uploading -= 1 }
        // Local safety net first, so the shot survives even if the upload fails.
        if await PhotoSaver.live.autoSave(photo, enabled: AutoSaveSetting().isEnabled) == .accessDenied {
            saveNotice = PhotosAccessMessage.denied
        }
        do {
            let item = try await api.share(photo, in: group.id)
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = switch error.statusCode {
            case 410: "This group has ended, so the photo wasn't shared."
            case 413: "The group's storage is full, so the photo wasn't shared."
            default: "Couldn't share the photo (error \(error.statusCode))."
            }
        } catch {
            errorMessage = "Couldn't share the photo: \(error.localizedDescription)"
        }
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
