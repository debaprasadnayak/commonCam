import CommonCamKit
import SwiftUI

@main
struct CommonCamApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let api: APIClient
    @State private var uploads: UploadCenter

    init() {
        let api = APIClient(baseURL: Bundle.main.apiBaseURL, identity: DeviceIdentity(store: KeychainTokenStore()))
        self.api = api
        _uploads = State(initialValue: UploadCenter(api: api))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(api: api)
                .environment(uploads)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await uploads.send() } }
        }
    }
}

private extension Bundle {
    var apiBaseURL: URL {
        URL(string: object(forInfoDictionaryKey: "APIBaseURL") as! String)!
    }
}
