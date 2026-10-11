import SwiftUI
import FWMFeatureUI

@main
struct LanaDemoApp: App {
    /// Switched on the Accounts screen; changing it reloads Lana with that dataset (chats and added accounts persist).
    @AppStorage(DemoStore.Choice.storageKey) private var choice = DemoStore.Choice.threeYear.rawValue
    private var seedURL: URL? { Bundle.main.url(forResource: "seed-v1", withExtension: "json") }
    /// The chosen dataset, falling back to the September sample if it can't be loaded.
    private var store: DemoStore? {
        if choice == DemoStore.Choice.threeYear.rawValue, let url = DemoStore.threeYearURL, let store = try? DemoStore(fixtureURL: url) { return store }
        return seedURL.flatMap { try? DemoStore(fixtureURL: $0) }
    }
    var body: some Scene {
        WindowGroup {
            if let store {
                LanaRootView(store: store, unlocker: NativeVaultUnlocker()).id(choice)
            } else {
                ContentUnavailableView("Demo data unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The bundled seed-v1.json could not be loaded."))
            }
        }
    }
}
