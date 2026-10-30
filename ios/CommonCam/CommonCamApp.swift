import CommonCamKit
import SwiftUI

@main
struct CommonCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(api: APIClient(
                baseURL: Bundle.main.apiBaseURL,
                identity: DeviceIdentity(store: KeychainTokenStore())
            ))
        }
    }
}

private extension Bundle {
    var apiBaseURL: URL {
        URL(string: object(forInfoDictionaryKey: "APIBaseURL") as! String)!
    }
}
