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
    @State private var shownContributor: Contributor?
    @State private var saveProgress: BulkSaveProgress?
    @State private var saveNotice: String?
    @State private var pendingDelete: GalleryItem?
    @State private var reporting: ReportTarget?

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
            let stats = ContributorStats(items: items)
            if !stats.counts.isEmpty {
                ContributorFilterBar(stats: stats, total: items.count, selection: $shownContributor)
            }
            if items.isEmpty && uploading == 0 {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle", description: Text("Tap the camera to add the first one."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(items.contributed(by: shownContributor)) { item in
                    GalleryTile(item: item, isTopContributor: stats.top.map { $0.memberId == item.contributor.memberId } ?? false)
                        .contextMenu {
                            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                                Task { await save([item]) }
                            }
                            .disabled(saveProgress != nil)
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
                AsyncImage(url: item.downloadUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
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
            .accessibilityLabel("Photo by \(item.contributor.displayName)\(item.isHidden ? ", reported, hidden from guests" : "")")
    }
}
