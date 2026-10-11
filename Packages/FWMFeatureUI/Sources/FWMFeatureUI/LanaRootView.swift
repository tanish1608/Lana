import SwiftUI

/// Entry point the iOS host embeds. Tabs: Money, Budget, Split, Vault.
public struct LanaRootView: View {
    let store: DemoStore
    let unlocker: VaultUnlocking
    @State private var log: [String] = []

    public init(store: DemoStore, unlocker: VaultUnlocking = SimulatedVaultUnlocker()) {
        self.store = store
        self.unlocker = unlocker
    }

    public var body: some View {
        TabView {
            MoneyScreen(store: store).tabItem { Label("Money", systemImage: "chart.bar") }
            BudgetScreen(store: store, onAdopt: { log.insert($0, at: 0) }).tabItem { Label("Budget", systemImage: "chart.pie") }
            SplitScreen(store: store, onAction: { log.insert($0, at: 0) }).tabItem { Label("Split", systemImage: "receipt") }
            VaultScreen(unlocker: unlocker, log: log).tabItem { Label("Vault", systemImage: "lock") }
        }
        .tint(Theme.accent)
    }
}

/// Loads the repo's seed fixture; shows a clear error if it is missing.
public struct LanaDemoRoot: View {
    public init() {}
    public var body: some View {
        if let store = DemoStore.repoSeed() { LanaRootView(store: store) }
        else { Text("Couldn’t load fixtures/seed-v1.json").padding() }
    }
}

#Preview("Lana") { LanaDemoRoot() }
