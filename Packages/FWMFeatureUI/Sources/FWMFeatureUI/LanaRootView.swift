import SwiftUI
import FWMCore
import FinanceAI

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
    @State private var budgetChatDecisions: [BudgetChatDecision] = []
    @State private var budgetReview = 0
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
            section(.budget) { BudgetScreen(store: store, unlocker: unlocker, onSelection: { accepted, useHistory in
                chat.updateBudget(accepted: accepted, useHistory: useHistory)
                store.dataset = chat.dataset
                if var split = store.reviewedResult { split.provenance.datasetVersion = chat.dataset.datasetVersion; store.reviewedResult = split }
                budgetAdopted = false
                chat.journal("budget_selection", "Budget plan has \(accepted.count) kept idea\(accepted.count == 1 ? "" : "s")\(useHistory ? "" : ", preference history off")",
                             details: ["kept": accepted.sorted().joined(separator: ","), "use_history": String(useHistory)])
            }, onAdopt: { record("plan_adopted", $0); budgetAdopted = true; chat.budgetAdopted = true },
                onApprove: { record("plan_item_confirmed", $0) }, onPlanChange: { plannedCents = $0 },
                chatDecisions: budgetChatDecisions, reviewRequest: budgetReview) }
            section(.split) { SplitScreen(store: store, isActive: tab == .split, onReview: { receipt, assignments, payer, result in
                chat.review(receipt: receipt, assignments: assignments, payerID: payer)
                store.dataset = chat.dataset
                store.reviewedResult = try? SplitEngine.prepareSplit(receipt: receipt, assignments: assignments, payerId: payer,
                    contacts: store.dataset.contacts ?? [], datasetVersion: store.dataset.datasetVersion, dataMode: receipt.receiptId.hasPrefix("local-") ? .cached : store.dataset.dataMode)
                record("split_reviewed", "Reviewed split · \(result.outstandingCents) cents outstanding; nothing sent",
                       details: ["receipt_id": receipt.receiptId, "total_cents": String(receipt.totalCents), "payer_id": payer])
            }, onInvalidate: { chat.reviewedSplit = nil; store.reviewedResult = nil }, onAction: { record("split_action", $0) }, dinnerRequest: dinnerRequest, states: $requestStates) }
            section(.accounts) { AccountsScreen(store: store, dataset: chat.dataset, unlocker: unlocker, log: log, relay: relay, chat: chat, isActive: tab == .accounts,
                onLink: { account, txns in
                    chat.addAccount(account, transactions: txns); syncStore()
                    record("account_imported", "Imported \(account.institution) \(AccountDisplay(account).subtitle) · \(txns.count) transactions, on this iPhone",
                           details: ["account_id": account.accountId, "institution": account.institution, "kind": account.kind])
                }, onConnect: { url, label, ids in
                    Task { if let note = await chat.saveSimpleFIN(accessURL: url, label: label, accountIDs: ids) { chat.status = note } }
                }, onRemove: { id in
                    let removed = chat.dataset.accounts.first { $0.accountId == id }
                    chat.removeImportedAccount(id); syncStore()
                    if let removed { record("account_removed", "Removed \(removed.institution) \(AccountDisplay(removed).subtitle) from Lana", details: ["account_id": id]) }
                }) }
        }
        .overlay {
            if showChat {
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { setChat(false) }.accessibilityHidden(true)
                        ChatPanel(controller: chat, onJump: jump, onClose: { setChat(false) }, perform: perform)
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
        .task {
            await chat.restore()
            syncStore()
            // The Approvals list survives relaunch; anything recorded this session before the read is kept on top.
            let saved = await chat.approvalLog()
            log = log.filter { !saved.contains($0) } + saved
            chat.requestRoster = roster(requestStates)
        }
        .onChange(of: requestStates) { old, states in
            chat.requestStates = Dictionary(uniqueKeysWithValues: states.map { (name($0.key), $0.value.label) })
            chat.requestRoster = roster(states)
            for (id, state) in states where old[id] != state {
                chat.journal("request_state", "\(name(id)) request marked \(state.label)", details: ["contact_id": id, "state": state.label])
            }
        }
    }

    /// Screens that read the store see the session dataset; a reviewed split follows its new version.
    private func syncStore() {
        store.dataset = chat.dataset
        if var split = store.reviewedResult { split.provenance.datasetVersion = chat.dataset.datasetVersion; store.reviewedResult = split }
    }

    /// Shows an entry in Approvals now and journals it so it is still there after relaunch.
    private func record(_ kind: String, _ summary: String, details: [String: String] = [:]) {
        log.insert(summary, at: 0)
        chat.journal(kind, summary, details: details)
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

    /// The dinner's reimbursement requests with their current states, for chat cards that mark one paid or sent.
    private func roster(_ states: [String: RequestState]) -> [ChatRequestRow] {
        (store.fixtureSplit()?.requests ?? []).map { r in
            ChatRequestRow(contactID: r.contactId, name: r.reviewedName, amountCents: r.amountCents, state: (states[r.contactId] ?? .draft).label)
        }
    }

    /// Performs a chat card the user confirmed. Each case re-checks the card against current state; adopting the plan
    /// goes through Budget's own review and Face ID rather than happening here.
    @MainActor private func perform(_ action: ChatAction) async throws -> String {
        let p = action.payload
        switch action.kind {
        case "keep_idea", "skip_idea":
            guard let id = p["idea_id"], let keep = p["keep"].flatMap(Bool.init),
                  let title = (PreviewBudgetPlan.swaps.map { ($0.id, $0.title) } + PreviewBudgetPlan.habits.map { ($0.id, $0.title) }).first(where: { $0.0 == id })?.1 else {
                throw ToolError(.staleData, "That idea is no longer in the plan.")
            }
            budgetChatDecisions.append(BudgetChatDecision(ideaID: id, keep: keep))
            return keep ? "Kept “\(title)” in your plan. It now counts toward the $150 goal." : "Skipped “\(title)”."
        case "adopt_plan":
            guard !budgetAdopted else { return "The current plan is already adopted." }
            jump(.budget)
            budgetReview += 1
            return "Opened the plan review in Budget. Confirm with Face ID to adopt it."
        case "mark_request":
            guard let id = p["contact_id"], let state = p["state"].flatMap(RequestState.init(rawValue:)),
                  store.fixtureSplit()?.requests.contains(where: { $0.contactId == id }) == true else { throw ToolError(.staleData, "That request isn't part of the current split.") }
            requestStates[id] = state
            return "\(name(id)) is now marked \(state.label)."
        case "recategorize":
            guard let category = p["category"], let ids = p["transaction_ids"]?.split(separator: ",").map(String.init), !ids.isEmpty else {
                throw ToolError(.invalidArguments, "That change is incomplete.")
            }
            let moved = chat.recategorize(Set(ids), to: category)
            guard moved > 0 else { throw ToolError(.staleData, "Those purchases already changed. Ask again for current figures.") }
            syncStore()
            return "Moved \(moved) purchase\(moved == 1 ? "" : "s") to \(category). Totals and the budget use the new category."
        case "open_screen":
            switch p["screen"] {
            case "money": jump(.money)
            case "budget": jump(.budget)
            case "split": jump(.split)
            case "accounts": jump(.accounts)
            default: setChat(false); tab = .home
            }
            return "Opened."
        case "remove_account":
            guard let id = p["account_id"], let account = chat.dataset.accounts.first(where: { $0.accountId == id }), AccountDisplay(account).isImported else {
                throw ToolError(.staleData, "That account is no longer connected.")
            }
            chat.removeImportedAccount(id); syncStore()
            record("account_removed", "Removed \(account.institution) \(AccountDisplay(account).subtitle) from Lana", details: ["account_id": id])
            return "Removed \(account.institution) \(AccountDisplay(account).subtitle)."
        default:
            throw ToolError(.unknownTool, "Lana can't perform that change.")
        }
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
