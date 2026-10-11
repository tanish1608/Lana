import SwiftUI

/// Entry point the iOS host embeds. Sections: Home, Budget, Split, Accounts. Money is pushed from Home.
/// A floating dock replaces the system tab bar; its Lana button opens the chat from anywhere.
public struct LanaRootView: View {
    let store: DemoStore
    let unlocker: VaultUnlocking
    @State private var log: [String] = []
    @State private var tab = LanaTab.home
    @State private var requestStates: [String: RequestState] = [:]
    @State private var budgetAdopted = false
    @State private var homePath = NavigationPath()
    @State private var showChat = false
    @State private var chat: [ChatMessage] = []

    public init(store: DemoStore, unlocker: VaultUnlocking = SimulatedVaultUnlocker()) {
        self.store = store
        self.unlocker = unlocker
    }

    public var body: some View {
        // All four stay alive so each keeps its place and state while you move around.
        ZStack {
            section(.home) { HomeScreen(store: store, tab: $tab, requestStates: requestStates, budgetAdopted: budgetAdopted, path: $homePath, openChat: { showChat = true }) }
            section(.budget) { BudgetScreen(store: store, onAdopt: { log.insert($0, at: 0); budgetAdopted = true }) }
            section(.split) { SplitScreen(store: store, onAction: { log.insert($0, at: 0) }, states: $requestStates) }
            section(.accounts) { AccountsScreen(store: store, unlocker: unlocker, log: log) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { LanaDock(tab: $tab, chatOpen: showChat, toggleChat: { showChat.toggle() }) }
        .tint(Theme.accent)
        .sheet(isPresented: $showChat) { ChatSheet(store: store, messages: $chat, onJump: jump) }
        .onAppear { if chat.isEmpty { chat = [ChatMessage(mine: false, text: "Hi \(store.dataset.user.displayName ?? "there"). Ask me anything about your money.")] } }
    }

    private func section<V: View>(_ t: LanaTab, @ViewBuilder _ content: () -> V) -> some View {
        content().opacity(tab == t ? 1 : 0).allowsHitTesting(tab == t).accessibilityHidden(tab != t)
    }

    private func jump(_ j: ChatMessage.Jump) {
        showChat = false
        switch j {
        case .money: tab = .home; homePath = NavigationPath([HomeRoute.money])
        case .budget: tab = .budget
        case .split: tab = .split
        case .accounts: tab = .accounts
        }
    }
}

/// Floating dock: a pill of sections where the current one opens up to show its name, and Lana's orb beside it.
struct LanaDock: View {
    @Binding var tab: LanaTab
    let chatOpen: Bool
    var toggleChat: () -> Void

    private static func item(_ t: LanaTab) -> (label: String, icon: String) {
        switch t {
        case .home: return ("Home", "house.fill")
        case .budget: return ("Budget", "chart.pie.fill")
        case .split: return ("Split", "person.2.fill")
        case .accounts: return ("Accounts", "building.columns.fill")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(LanaTab.allCases, id: \.self) { t in
                    let on = t == tab, it = Self.item(t)
                    Button { withAnimation(.spring(duration: 0.35, bounce: 0.25)) { tab = t } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: it.icon).font(.system(size: 17, weight: .semibold))
                            if on { Text(it.label).font(.subheadline.weight(.semibold)).fixedSize() }
                        }
                        .foregroundStyle(on ? Theme.pillOnText : Theme.ink2)
                        .padding(.horizontal, on ? 16 : 0).frame(minWidth: 48, minHeight: 48)
                        .background { if on { Capsule().fill(Theme.ink).shadow(color: .black.opacity(0.25), radius: 6, y: 3) } }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(it.label).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.edge))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
            Spacer(minLength: 0)
            Button(action: toggleChat) {
                LanaOrb(size: 60).shadow(color: Color.indigo.opacity(0.45), radius: 14, y: 8)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(chatOpen ? "Close chat with Lana" : "Chat with Lana")
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
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
