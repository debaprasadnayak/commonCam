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
    @State private var reporting: ReportTarget?

    var body: some View {
        ScrollView {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding()
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
        .sheet(item: $reporting) { target in
            ReportSheet(api: api, groupID: group.id, target: target) { Task { await reload() } }
        }
    }

    private func reload() async {
        if let latest = try? await api.gallery(of: group.id) { items = latest }
    }

    private func share(_ photo: CapturedPhoto) async {
        uploading += 1
        defer { uploading -= 1 }
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
                .font(.caption2)
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Photo by \(item.contributor.displayName)\(item.isHidden ? ", reported, hidden from guests" : "")")
    }
}
