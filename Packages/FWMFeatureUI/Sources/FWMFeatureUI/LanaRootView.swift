import SwiftUI

/// Entry point the iOS host embeds. Tabs: Home, Budget, Split, Vault. Money is pushed from Home.
public struct LanaRootView: View {
    let store: DemoStore
    let unlocker: VaultUnlocking
    @State private var log: [String] = []
    @State private var tab = LanaTab.home
    @State private var requestStates: [String: RequestState] = [:]
    @State private var budgetAdopted = false

    public init(store: DemoStore, unlocker: VaultUnlocking = SimulatedVaultUnlocker()) {
        self.store = store
        self.unlocker = unlocker
    }

    public var body: some View {
        TabView(selection: $tab) {
            HomeScreen(store: store, tab: $tab, requestStates: requestStates, budgetAdopted: budgetAdopted)
                .tabItem { Label("Home", systemImage: "house") }.tag(LanaTab.home)
            BudgetScreen(store: store, onAdopt: { log.insert($0, at: 0); budgetAdopted = true })
                .tabItem { Label("Budget", systemImage: "chart.pie") }.tag(LanaTab.budget)
            SplitScreen(store: store, onAction: { log.insert($0, at: 0) }, states: $requestStates)
                .tabItem { Label("Split", systemImage: "receipt") }.tag(LanaTab.split)
            VaultScreen(unlocker: unlocker, log: log).tabItem { Label("Vault", systemImage: "lock") }.tag(LanaTab.vault)
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
