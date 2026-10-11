import SwiftUI
import FWMFeatureUI

@main
struct LanaDemoApp: App {
    var body: some Scene {
        WindowGroup {
            if let url = Bundle.main.url(forResource: "seed-v1", withExtension: "json"),
               let store = try? DemoStore(fixtureURL: url) {
                LanaRootView(store: store, unlocker: NativeVaultUnlocker())
            } else {
                ContentUnavailableView("Demo data unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The bundled seed-v1.json could not be loaded."))
            }
        }
    }
}
