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
        // All four stay alive so each keeps its place and state while you move around.
        ZStack {
            section(.home) { HomeScreen(store: store, tab: $tab, requestStates: requestStates, budgetAdopted: budgetAdopted, budgetSavingsCents: (try? BudgetProjection.make(dataset: chat.dataset, period: "2026-09", accepted: chat.accepted, useHistory: chat.useHistory))?.savingsCents ?? 0, path: $homePath, openChat: { setChat(true) }) }
            section(.budget) { BudgetScreen(store: store, unlocker: unlocker, onSelection: { chat.updateBudget(accepted: $0, useHistory: $1)
                store.dataset = chat.dataset
                if var split = store.reviewedResult { split.provenance.datasetVersion = chat.dataset.datasetVersion; store.reviewedResult = split }
                budgetAdopted = false }, onAdopt: { log.insert($0, at: 0); budgetAdopted = true; chat.budgetAdopted = true }) }
            section(.split) { SplitScreen(store: store, isActive: tab == .split, onReview: { receipt, assignments, payer, result in
                chat.review(receipt: receipt, assignments: assignments, payerID: payer)
                store.dataset = chat.dataset
                store.reviewedResult = try? SplitEngine.prepareSplit(receipt: receipt, assignments: assignments, payerId: payer,
                    contacts: store.dataset.contacts ?? [], datasetVersion: store.dataset.datasetVersion, dataMode: receipt.receiptId.hasPrefix("local-") ? .cached : store.dataset.dataMode)
                log.insert("Reviewed split · \(result.outstandingCents) cents outstanding; nothing sent", at: 0)
            }, onInvalidate: { chat.reviewedSplit = nil; store.reviewedResult = nil }, onAction: { log.insert($0, at: 0) }, states: $requestStates) }
            section(.accounts) { AccountsScreen(store: store, unlocker: unlocker, log: log, relay: relay, isActive: tab == .accounts) }
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

    private func name(_ id: String) -> String { store.dataset.contacts?.first { $0.contactId == id }?.reviewedName ?? id }

    private func setChat(_ open: Bool) { withAnimation(.spring(duration: 0.35, bounce: 0.2)) { showChat = open } }

    private func section<V: View>(_ t: LanaTab, @ViewBuilder _ content: () -> V) -> some View {
        content().opacity(tab == t ? 1 : 0).allowsHitTesting(tab == t).accessibilityHidden(tab != t)
    }

    private func jump(_ j: LanaChatJump) {
        setChat(false)
        switch j {
        case .money: tab = .home; homePath = NavigationPath([HomeRoute.money])
        case .budget: tab = .budget
        case .split: tab = .split
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
        case .split: return ("Split", "person.2.fill")
        case .accounts: return ("Accounts", "creditcard.fill")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Two equal halves so the orb's gap stays centred whichever pill is open.
            HStack(spacing: 0) { button(.home); button(.budget) }.frame(maxWidth: .infinity)
            Color.clear.frame(width: 76, height: 1)
            HStack(spacing: 0) { button(.split); button(.accounts) }.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 7).frame(height: 64).frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Theme.edge))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        .overlay(alignment: .top) {
            Button(action: toggleChat) {
                LanaOrb(size: 62, symbol: chatOpen ? "xmark" : "sparkles")
                    .padding(4).background(Theme.bg, in: Circle())
                    .shadow(color: Color(red: 0.37, green: 0.36, blue: 0.9).opacity(0.5), radius: 14, y: 8)
            }
            .buttonStyle(PressScaleStyle())
            .offset(y: -26)
            .accessibilityLabel(chatOpen ? "Close chat with Lana" : "Chat with Lana")
        }
        .padding(.horizontal, 12).padding(.top, 34).padding(.bottom, 4)
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
