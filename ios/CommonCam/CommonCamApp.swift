import CommonCamKit
import SwiftUI

@main
struct CommonCamApp: App {
    private let api = APIClient(
        baseURL: Bundle.main.apiBaseURL,
        identity: DeviceIdentity(store: KeychainTokenStore())
    )

    var body: some Scene {
        WindowGroup {
            // As a test host the UI stays idle so its launch work (StoreKit, API) can't race the tests.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Text("Running tests")
            } else {
                ContentView(api: api, purchaser: TierPurchaser { [api] tier, signedTransaction in
                    try await api.createPaidGroup(tier: tier, signedTransaction: signedTransaction)
                })
            }
        }
    }
}

private extension Bundle {
    var apiBaseURL: URL {
        URL(string: object(forInfoDictionaryKey: "APIBaseURL") as! String)!
    }
}
