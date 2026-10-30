import CommonCamKit
import Photos
import SwiftUI

/// PhotoKit behind `PhotoLibrary`, using add-only access (we never read the user's library).
struct PhotoKitLibrary: PhotoLibrary {
    func requestAddAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    func addPhoto(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    func addVideo(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, data: data, options: nil)
        }
    }
}

extension PhotoSaver {
    /// Saves the filtered version of photos that have a recipe, unless asked for originals (bulk "Save all").
    static let live = PhotoSaver(library: PhotoKitLibrary()) { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

enum PhotosAccessMessage {
    static let denied = "Photos access is off. Turn it on in Settings › commonCam › Photos to save photos."
}

/// The auto-save toggle shown on the home screen.
struct PhotosSettingsSection: View {
    @AppStorage(AutoSaveSetting.key) private var autoSave = true

    var body: some View {
        Section {
            Toggle("Save my photos to Photos", isOn: $autoSave)
        } header: {
            Text("Settings")
        } footer: {
            Text("Keeps a copy of each photo you take in your own Photos library. It doesn't use the group's storage.")
        }
    }
}
