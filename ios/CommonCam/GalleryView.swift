import CommonCamKit
import SwiftUI

/// The group's shared space: everyone's photos tagged with the contributor's fun name and colour, plus the camera.
struct GalleryView: View {
    let api: APIClient
    let group: EventGroup

    @Environment(UploadCenter.self) private var uploads
    @State private var items: [GalleryItem] = []
    @State private var isCameraOpen = false
    @State private var errorMessage: String?
    @State private var shownContributor: Contributor?
    @State private var saveProgress: BulkSaveProgress?
    @State private var saveNotice: String?
    @State private var pendingDelete: GalleryItem?
    @State private var reporting: ReportTarget?

    private var queued: [QueuedUpload] {
        uploads.uploads.filter { $0.groupID == group.id }.reversed()
    }

    var body: some View {
        ScrollView {
            if let problem = uploads.problem {
                Text(problem).foregroundStyle(.red).padding()
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding()
            }
            StorageNoticeBanner(groupID: group.id)
            if let saveProgress {
                ProgressView("Saving to Photos…", value: Double(saveProgress.done), total: Double(max(saveProgress.total, 1)))
                    .padding()
            }
            if let saveNotice {
                Text(saveNotice).foregroundStyle(.secondary).padding()
            }
            let stats = ContributorStats(items: items)
            if !stats.counts.isEmpty {
                ContributorFilterBar(stats: stats, total: items.count, selection: $shownContributor)
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
                ForEach(items.contributed(by: shownContributor)) { item in
                    NavigationLink {
                        if item.isVideo { VideoDetailView(item: item) } else { ItemDetailView(item: item) }
                    } label: {
                        GalleryTile(item: item, isTopContributor: stats.top.map { $0.memberId == item.contributor.memberId } ?? false)
                    }
                    .contextMenu {
                        if !item.isVideo { // clips are saved from their player (VideoDetailView)
                            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                                Task { await save([item]) }
                            }
                            .disabled(saveProgress != nil)
                        }
                        if item.canDelete {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item }
                        }
                        ItemModerationMenu(api: api, groupID: group.id, item: item, report: { reporting = $0 }, changed: reload)
                    }
                }
            }
            Link("Takedown requests: \(Contact.takedownEmail)", destination: Contact.takedownMailURL)
                .font(.footnote)
                .padding()
        }
        .navigationTitle("Gallery")
        .toolbar {
            Button("Save all to Photos", systemImage: "square.and.arrow.down.on.square") {
                Task { await saveAll() }
            }
            .disabled(items.isEmpty || saveProgress != nil)
            Button("Take photo", systemImage: "camera") { isCameraOpen = true }
                .disabled(group.isReadOnly) // ended groups take no uploads
        }
        .fullScreenCover(isPresented: $isCameraOpen) {
            CameraScreen(onCapture: { photo in Task { await share(photo) } }, onRecord: { clip in Task { await share(clip) } })
        }
        .task {
            // Re-listing also renews the short-lived download URLs.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .refreshable { await reload() }
        .confirmationDialog(
            "Delete this photo for everyone?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { Task { await delete(item) } }
        }
        .sheet(item: $reporting) { target in
            ReportSheet(api: api, groupID: group.id, target: target) { Task { await reload() } }
        }
        .onChange(of: uploads.confirmed.count) { Task { await reload() } }
    }

    private func reload() async {
        if let latest = try? await api.gallery(of: group.id) { items = latest }
        if let storage = try? await api.storage(of: group.id) { await uploads.resumeIfRoom(in: group.id, storage: storage) }
    }

    private func saveAll() async {
        await reload() // fresh download URLs: they expire after 15 minutes
        await save(items, originals: true) // SPEC.md section 9.2: bulk-downloading originals, videos included
    }

    private func save(_ toSave: [GalleryItem], originals: Bool = false) async {
        saveNotice = nil
        saveProgress = BulkSaveProgress(done: 0, total: toSave.count)
        let report = await PhotoSaver.live.save(toSave, originals: originals) { progress in
            await MainActor.run { saveProgress = progress }
        }
        saveProgress = nil
        saveNotice = if report.accessDenied {
            PhotosAccessMessage.denied
        } else if report.failed.isEmpty {
            "Saved \(report.saved.count) item\(report.saved.count == 1 ? "" : "s") to Photos."
        } else {
            "Saved \(report.saved.count) of \(toSave.count) to Photos; \(report.failed.count) couldn't be saved. Try those again."
        }
    }

    private func delete(_ item: GalleryItem) async {
        do {
            try await api.deleteItem(item.id, in: group.id)
            items.removeAll { $0.id == item.id }
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = error.statusCode == 403 ? "You can only delete your own photos." : "Couldn't delete the photo (error \(error.statusCode))."
        } catch {
            errorMessage = "Couldn't delete the photo: \(error.localizedDescription)"
        }
    }

    private func share(_ photo: CapturedPhoto) async {
        // Local safety net first, so the shot survives even if the upload fails.
        if await PhotoSaver.live.autoSave(photo, enabled: AutoSaveSetting().isEnabled) == .accessDenied {
            saveNotice = PhotosAccessMessage.denied
        }
        await uploads.enqueue(photo, in: group.id)
    }

    private func share(_ clip: CapturedVideo) async {
        if await VideoSaver.autoSave(clip, enabled: AutoSaveSetting().isEnabled) == .accessDenied {
            saveNotice = PhotosAccessMessage.denied
        }
        await uploads.enqueue(clip, in: group.id)
    }
}

/// "Everyone" plus one chip per person with their count; the top contributor gets a crown.
private struct ContributorFilterBar: View {
    let stats: ContributorStats
    let total: Int
    @Binding var selection: Contributor?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip(isSelected: selection == nil, action: { selection = nil }) {
                    Text("Everyone \(total)")
                }
                ForEach(stats.counts, id: \.contributor.memberId) { entry in
                    let isTop = stats.top.map { $0.memberId == entry.contributor.memberId } ?? false
                    chip(isSelected: selection.map { $0.memberId == entry.contributor.memberId } ?? false,
                         action: { selection = entry.contributor }) {
                        Circle().fill(Color(hex: entry.contributor.colour)).frame(width: 10, height: 10)
                        Text("\(entry.contributor.displayName) \(entry.count)")
                        if isTop { Image(systemName: "crown.fill").foregroundStyle(.yellow) }
                    }
                    .accessibilityLabel("\(entry.contributor.displayName), \(entry.count) photo\(entry.count == 1 ? "" : "s")\(isTop ? ", top contributor" : "")")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func chip<Label: View>(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { label() }
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GalleryTile: View {
    let item: GalleryItem
    let isTopContributor: Bool

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Group {
                    if item.isVideo { VideoThumbnail(url: item.downloadUrl) } else { FilteredThumbnail(item: item) }
                }
                .pendingReviewBlur(item.isHidden, canReveal: false)
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if item.isHidden {
                    Label("Reported, hidden from guests", systemImage: "eye.slash")
                        .labelStyle(.iconOnly)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Label {
                    Text(item.contributor.displayName).lineLimit(1)
                } icon: {
                    Circle().fill(Color(hex: item.contributor.colour)).frame(width: 10, height: 10)
                }
                .overlay(alignment: .topTrailing) {
                    if isTopContributor {
                        Image(systemName: "crown.fill").font(.system(size: 8)).foregroundStyle(.yellow).offset(x: 4, y: -4)
                    }
                }
                .font(.caption2)
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.isVideo ? "Video" : "Photo") by \(item.contributor.displayName)\(item.isHidden ? ", reported, hidden from guests" : "")")
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
                if upload.isVideo {
                    VideoThumbnail(url: file, opacity: 0.6)
                } else if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill().opacity(0.6)
                }
            }
            .task(id: file) {
                guard !upload.isVideo, let image = UIImage(contentsOfFile: file.path()) else { return }
                let scale = 300 / max(image.size.width, image.size.height, 1)
                thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                Label(
                    upload.failureMessage ?? (upload.isWaitingForStorage ? "Waiting for space" : "Pending"),
                    systemImage: upload.isPending ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill"
                )
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
