// Quick look on a Mac: `swift run --package-path Packages/FWMFeatureUI LanaMac`. Not the iOS app.
#if os(macOS)
import SwiftUI
import FWMFeatureUI

struct LanaMacApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Lana (demo data)") { LanaDemoRoot().frame(width: 400, height: 860) }
            .windowResizability(.contentSize)
    }
}
LanaMacApp.main()
#else
print("LanaMac runs on macOS only. Use the FWMFeatureUI library in the iOS host.")
#endif
