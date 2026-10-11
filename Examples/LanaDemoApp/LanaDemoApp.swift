import SwiftUI
import FWMFeatureUI

@main
struct LanaDemoApp: App {
    /// Switched on the Accounts screen; changing it reloads Lana with that dataset (chats and added accounts persist).
    @AppStorage(DemoStore.Choice.storageKey) private var choice = DemoStore.Choice.threeYear.rawValue
    private var datasetURL: URL? {
        choice == DemoStore.Choice.threeYear.rawValue ? DemoStore.threeYearURL : Bundle.main.url(forResource: "seed-v1", withExtension: "json")
    }
    var body: some Scene {
        WindowGroup {
            if let url = datasetURL, let store = try? DemoStore(fixtureURL: url) {
                LanaRootView(store: store, unlocker: NativeVaultUnlocker()).id(choice)
            } else {
                ContentUnavailableView("Demo data unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The bundled seed-v1.json could not be loaded."))
            }
        }
    }
}
