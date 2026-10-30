import CommonCamKit
import SwiftUI

/// Host/co-host: storage usage with the 80% and 100% warnings (SPEC.md section 8). Polls while visible so
/// co-hosts (whose group JSON is from when they joined) see it fill up; any fetch that shows room again
/// resumes this phone's paused uploads at once.
struct StorageSection: View {
    let api: APIClient
    let group: EventGroup

    @Environment(UploadCenter.self) private var uploads
    @State private var storage: GroupStorage?

    var body: some View {
        let storage = storage ?? group.storage
        Section("Storage") {
            ProgressView(value: storage.fractionUsed) {
                Text("\(bytes(storage.usedBytes)) of \(bytes(storage.capBytes)) used")
            }
            .tint(storage.level == .ok ? .accentColor : storage.level == .nearlyFull ? .orange : .red)
            if let warning = storage.hostWarning {
                Label(warning, systemImage: storage.level == .full ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(storage.level == .full ? .red : .orange)
            }
        }
        // Restarts when an upgrade or add-on replaces the group, so the new cap shows and uploads resume straight away.
        .task(id: group) {
            self.storage = group.storage
            while !Task.isCancelled {
                await uploads.resumeIfRoom(in: group.id, storage: self.storage ?? group.storage)
                try? await Task.sleep(for: .seconds(30))
                if let latest = try? await api.storage(of: group.id) { self.storage = latest }
            }
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}

/// Guest-facing note about this phone's shots held back by the group's full storage, including the clear
/// "not shared" message once they've waited 24 hours (those can be dismissed, which forgets them).
struct StorageNoticeBanner: View {
    let groupID: String

    @Environment(UploadCenter.self) private var uploads

    var body: some View {
        if let notice = uploads.uploads.storageNotice(in: groupID) {
            let dropped = uploads.uploads.filter { $0.groupID == groupID && $0.failure == 413 }
            VStack(alignment: .leading, spacing: 8) {
                Label(notice, systemImage: dropped.isEmpty ? "externaldrive.badge.timemachine" : "exclamationmark.triangle.fill")
                    .foregroundStyle(dropped.isEmpty ? Color.primary : Color.red)
                if !dropped.isEmpty {
                    Button("Dismiss") {
                        Task { for upload in dropped { await uploads.remove(upload) } }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}
