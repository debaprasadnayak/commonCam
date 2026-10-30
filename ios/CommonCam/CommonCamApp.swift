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
        PushNotifications.api = api
        _uploads = State(initialValue: UploadCenter(api: api))
    }

    var body: some Scene {
        WindowGroup {
            // As a test host the UI stays idle so its launch work (StoreKit, API) can't race the tests.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Text("Running tests")
            } else {
                ContentView(api: api, purchaser: TierPurchaser { [api] tier, signedTransaction in
                    try await api.createPaidGroup(tier: tier, signedTransaction: signedTransaction)
                })
                .environment(uploads)
                .task { await PushNotifications.requestPermissionAndRegister() }
            }
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
