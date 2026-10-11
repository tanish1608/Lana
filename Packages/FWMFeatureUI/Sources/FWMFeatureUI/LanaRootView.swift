import SwiftUI
import FWMCore

/// Entry point the iOS host embeds. Sections: Home, Budget, Split, Accounts. Money is pushed from Home.
/// A floating glass dock replaces the system tab bar; its centre orb toggles the Lana chat from anywhere.
public struct LanaRootView: View {
    let store: DemoStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var relay: LanaRelayConnection
    let unlocker: VaultUnlocking
    @State private var log: [String] = []
    @State private var tab = LanaTab.home
    @State private var requestStates: [String: RequestState] = [:]
    @State private var budgetAdopted = false
    @State private var plannedCents = 0
    @State private var dinnerRequest = 0
    @State private var homePath = NavigationPath()
    @State private var showChat = false
    @State private var chat: LanaChatController

    public init(store: DemoStore, unlocker: VaultUnlocking = SimulatedVaultUnlocker()) {
        self.store = store
        self.unlocker = unlocker
        let chat = LanaChatController(dataset: store.dataset)
        _chat = State(initialValue: chat)
        _relay = State(initialValue: LanaRelayConnection(chat: chat))
    }

    public var body: some View {
        // Native tab containment keeps each navigation stack's toolbar scoped to its section.
        LanaSectionHost(selection: $tab) {
            section(.home) { HomeScreen(store: store, tab: $tab, requestStates: requestStates, budgetAdopted: budgetAdopted, plannedCents: plannedCents, path: $homePath, openChat: { setChat(true) }, openDinner: { dinnerRequest += 1 }) }
            section(.budget) { BudgetScreen(store: store, unlocker: unlocker, onSelection: { chat.updateBudget(accepted: $0, useHistory: $1)
                store.dataset = chat.dataset
                if var split = store.reviewedResult { split.provenance.datasetVersion = chat.dataset.datasetVersion; store.reviewedResult = split }
                budgetAdopted = false }, onAdopt: { log.insert($0, at: 0); budgetAdopted = true; chat.budgetAdopted = true },
                onApprove: { log.insert($0, at: 0) }, onPlanChange: { plannedCents = $0 }) }
            section(.split) { SplitScreen(store: store, isActive: tab == .split, onReview: { receipt, assignments, payer, result in
                chat.review(receipt: receipt, assignments: assignments, payerID: payer)
                store.dataset = chat.dataset
                store.reviewedResult = try? SplitEngine.prepareSplit(receipt: receipt, assignments: assignments, payerId: payer,
                    contacts: store.dataset.contacts ?? [], datasetVersion: store.dataset.datasetVersion, dataMode: receipt.receiptId.hasPrefix("local-") ? .cached : store.dataset.dataMode)
                log.insert("Reviewed split · \(result.outstandingCents) cents outstanding; nothing sent", at: 0)
            }, onInvalidate: { chat.reviewedSplit = nil; store.reviewedResult = nil }, onAction: { log.insert($0, at: 0) }, dinnerRequest: dinnerRequest, states: $requestStates) }
            section(.accounts) { AccountsScreen(store: store, dataset: chat.dataset, unlocker: unlocker, log: log, relay: relay, isActive: tab == .accounts,
                onLink: { account, txns in
                    chat.addAccount(account, transactions: txns); syncStore()
                    log.insert("Imported \(account.institution) \(AccountDisplay(account).subtitle) · \(txns.count) transactions, on this iPhone", at: 0)
                }, onRemove: { chat.removeImportedAccount($0); syncStore() }) }
        }
        .overlay {
            if showChat {
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { setChat(false) }.accessibilityHidden(true)
                        ChatPanel(controller: chat, onJump: jump, onClose: { setChat(false) })
                            .frame(height: min(g.size.height - 8, max(320, g.size.height * 0.78)))
                            .padding(.horizontal, 10).padding(.bottom, 2)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            }
        }
        // The dock is added after the chat overlay so it stays lit and tappable while chat is open.
        .safeAreaInset(edge: .bottom, spacing: 0) { LanaDock(tab: $tab, chatOpen: showChat, toggleChat: { setChat(!showChat) }) }
        .tint(Theme.accent)
        .task(id: scenePhase) { await relay.setForeground(scenePhase == .active) }
        .task { await chat.restore() }
        .onChange(of: requestStates) { _, states in chat.requestStates = Dictionary(uniqueKeysWithValues: states.map { (name($0.key), $0.value.label) }) }
    }

    /// Screens that read the store see the session dataset; a reviewed split follows its new version.
    private func syncStore() {
        store.dataset = chat.dataset
        if var split = store.reviewedResult { split.provenance.datasetVersion = chat.dataset.datasetVersion; store.reviewedResult = split }
    }

    private func name(_ id: String) -> String { store.dataset.contacts?.first { $0.contactId == id }?.reviewedName ?? id }

    private func setChat(_ open: Bool) { withAnimation(.spring(duration: 0.35, bounce: 0.2)) { showChat = open } }

    private func section<V: View>(_ t: LanaTab, @ViewBuilder _ content: () -> V) -> some View {
        #if os(iOS)
        // Hidden per tab: on the TabView itself the system bar still draws an empty glass capsule under the dock.
        content().toolbar(.hidden, for: .tabBar).tag(t)
        #else
        content().opacity(tab == t ? 1 : 0).allowsHitTesting(tab == t).accessibilityHidden(tab != t)
        #endif
    }

    private func jump(_ j: LanaChatJump) {
        setChat(false)
        switch j {
        case .money: tab = .home; homePath = NavigationPath([HomeRoute.money])
        case .budget: tab = .budget
        case .split: tab = .split; dinnerRequest += 1
        case .accounts: tab = .accounts
        }
    }
}

/// Floating glass dock: Home, Budget, [Lana orb], Split, Accounts. The current section opens into a filled
/// capsule with its name; the raised centre orb toggles chat.
struct LanaDock: View {
    @Binding var tab: LanaTab
    let chatOpen: Bool
    var toggleChat: () -> Void
    private static func item(_ t: LanaTab) -> (label: String, icon: String) {
        switch t {
        case .home: return ("Home", "house.fill")
        case .budget: return ("Budget", "chart.pie.fill")
        case .split: return ("Receipts", "doc.text.viewfinder")
        case .accounts: return ("Accounts", "creditcard.fill")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Two equal halves so the orb's gap stays centred whichever pill is open.
            HStack(spacing: 0) { button(.home); button(.budget) }.frame(width: 146)
            Color.clear.frame(width: 70, height: 1)
            HStack(spacing: 0) { button(.split); button(.accounts) }.frame(width: 146)
        }
        .padding(.horizontal, 6).frame(height: 64)
        // Floating glass: thin material, a soft top sheen, a bright top edge and a wide soft shadow.
        .background {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)))
        }
        .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.22), radius: 28, y: 16)
        .overlay(alignment: .top) {
            Button(action: toggleChat) {
                LanaOrb(size: 62, symbol: chatOpen ? "xmark" : "sparkles")
                    .padding(4).background(Theme.base, in: Circle())
                    .shadow(color: Color(red: 0.37, green: 0.36, blue: 0.9).opacity(0.5), radius: 14, y: 8)
            }
            .buttonStyle(PressScaleStyle())
            .offset(y: -26)
            .zIndex(5) // always above the capsule's edge, sheen and shadow
            .accessibilityLabel(chatOpen ? "Close chat with Lana" : "Chat with Lana")
        }
        .frame(maxWidth: .infinity).padding(.top, 34).padding(.bottom, 8)
    }

    private func button(_ t: LanaTab) -> some View {
        let on = t == tab, it = Self.item(t)
        return Button { withAnimation(.spring(duration: 0.35, bounce: 0.25)) { tab = t } } label: {
            HStack(spacing: 5) {
                Image(systemName: it.icon).font(.system(size: on ? 15 : 17, weight: .semibold))
                if on { Text(it.label).font(.footnote.weight(.semibold)).fixedSize() }
            }
            .foregroundStyle(on ? Theme.pillOnText : Theme.ink2)
            .padding(.horizontal, on ? 11 : 0).frame(minWidth: 44, minHeight: 46)
            .background { if on { Capsule().fill(Theme.ink).shadow(color: .black.opacity(0.25), radius: 6, y: 3) } }
            .fixedSize()
            .frame(maxWidth: on ? nil : .infinity).contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle()).layoutPriority(on ? 1 : 0)
        .accessibilityLabel(it.label).accessibilityAddTraits(on ? .isSelected : [])
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

private struct LanaSectionHost<Content: View>: View {
    @Binding var selection: LanaTab
    let content: Content
    init(selection: Binding<LanaTab>, @ViewBuilder content: () -> Content) {
        _selection = selection; self.content = content()
    }
    var body: some View {
        #if os(iOS)
        TabView(selection: $selection) { content }.toolbar(.hidden, for: .tabBar)
        #else
        ZStack { content }
        #endif
    }
}
