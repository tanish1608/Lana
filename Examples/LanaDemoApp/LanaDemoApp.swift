import SwiftUI
import FWMFeatureUI

// Minimal iOS host for Ashwin's feature screens. Demo data only: LanaDemoRoot reads
// fixtures/seed-v1.json from this checkout, so run it in the simulator on the Mac that built it.
@main
struct LanaDemoApp: App {
    var body: some Scene {
        WindowGroup { LanaDemoRoot() }
    }
}
