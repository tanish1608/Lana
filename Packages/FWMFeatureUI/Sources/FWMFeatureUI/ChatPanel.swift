import SwiftUI
import FWMCore

struct ChatMessage: Identifiable, Equatable {
    enum Jump: Equatable { case money, budget, split, accounts }
    struct Action: Equatable { let jump: Jump; let label: String }
    let id = UUID()
    let mine: Bool
    let text: String
    var actions: [Action] = []
}

/// Talk to Lana inside the app: a floating card above the dock. Replies in this build are deterministic,
/// built from MoneyEngine / SplitEngine results and the plan stand-in (same rules as `lanaReply()` in
/// preview/web/app.js). No model is called; the on-device model plugs in behind `reply(to:)`.
struct ChatPanel: View {
    let store: DemoStore
    let requestStates: [String: RequestState]
    var plannedCents = 0
    @Binding var messages: [ChatMessage]
    var onJump: (ChatMessage.Jump) -> Void
    var onClose: () -> Void
    @State private var draft = ""
    @State private var typing = false
    @FocusState private var focused: Bool

    private static let suggestions = ["Where did my money go?", "What’s my net worth?", "Who owes me?", "How do I save $150?", "Which accounts are connected?"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LanaOrb(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lana").font(.headline)
                    Text("Preview replies from your demo numbers").font(.caption.weight(.semibold)).foregroundStyle(Theme.warn).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.ink2)
                        .frame(width: 32, height: 32).background(Theme.line, in: Circle()).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close chat")
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.top, 10).padding(.bottom, 6)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(messages) { bubble($0) }
                        if typing { HStack { TypingDots(); Spacer() } }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14).padding(.top, 12)
                }
                .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: typing) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { send(s) }.font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 36)
                            .foregroundStyle(Theme.accent).background(Theme.accentSoft, in: Capsule())
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                TextField("Ask about your money", text: $draft).focused($focused).submitLabel(.send).onSubmit { send(draft) }
                    .padding(.horizontal, 16).frame(minHeight: 44).background(Theme.bg, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.edge))
                    .accessibilityLabel("Message Lana")
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Theme.lanaGradient, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityLabel("Send")
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        // Chat stays close to solid so replies read clearly over any screen.
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.glassEdge))
        .compositingGroup()
        .shadow(color: .black.opacity(0.10), radius: 3, y: 2)
        .shadow(color: .black.opacity(0.28), radius: 36, y: 18)
        .accessibilityAddTraits(.isModal)
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack(alignment: .bottom) {
            if m.mine { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 8) {
                Text(m.text).font(.subheadline)
                ForEach(m.actions, id: \.label) { a in
                    Button { onJump(a.jump) } label: {
                        Label(a.label, systemImage: "chevron.right").labelStyle(TrailingIcon()).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 34).foregroundStyle(.white).background(Theme.accent.gradient, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(m.mine ? .white : Theme.ink)
            .background(m.mine ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.bubbleIn), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !m.mine { Spacer(minLength: 40) }
        }
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !typing else { return }
        draft = ""
        messages.append(ChatMessage(mine: true, text: text))
        typing = true
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            messages.append(Self.reply(to: text, store: store, requestStates: requestStates, plannedCents: plannedCents))
            typing = false
        }
    }

    /// Deterministic intent match, first rule wins. Every number comes from the engines, never from this file.
    static func reply(to text: String, store: DemoStore, requestStates: [String: RequestState], plannedCents: Int = 0) -> ChatMessage {
        let q = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { q.contains($0) } }
        func say(_ t: String, _ a: ChatMessage.Action...) -> ChatMessage { ChatMessage(mine: false, text: t, actions: a) }
        guard case .success(let v) = store.moneyView(store.snapshotPeriod) else { return say("I couldn’t load your money just now.") }
        let f = v.flow, month = DemoStore.monthName(store.snapshotPeriod).components(separatedBy: " ").first ?? ""
        let stays = f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents

        if let c = v.categories.first(where: { q.contains($0.category.lowercased().components(separatedBy: " ").first ?? "\u{0}") }) {
            let n = c.transactionIds.count
            return say("\(c.category) was \(usd(c.totalCents)) in \(month), across \(n) \(n == 1 ? "payment" : "payments").", .init(jump: .money, label: "Open \(month)"))
        }
        if has("owe", "split", "dinner", "venmo", "paid", "tanish", "aryan") {
            let unpaid = store.unpaidRequests(requestStates)
            guard !unpaid.isEmpty else { return say("Everyone has settled up for dinner.", .init(jump: .split, label: "Open split")) }
            let parts = unpaid.map { "\($0.reviewedName) \(usd($0.amountCents, cents: true))" }.joined(separator: ", ")
            return say("You’re owed \(usd(unpaid.reduce(0) { $0 + $1.amountCents }, cents: true)) for dinner: \(parts). Nothing is sent until you approve it.", .init(jump: .split, label: "Review split"))
        }
        if has("save", "budget", "plan", "150", "cut") {
            let total = PreviewBudgetPlan.swaps.reduce(0) { $0 + $1.savingsCents } + PreviewBudgetPlan.habits.reduce(0) { $0 + $1.savingsCents }
            let top = PreviewBudgetPlan.swaps.sorted { $0.savingsCents > $1.savingsCents }.prefix(2).map { "\($0.title.lowercased()) (\(usd($0.savingsCents)))" }
            if plannedCents > 0 {
                let goal = PreviewBudgetPlan.goalCents
                return say("You’ve kept \(usd(plannedCents)) a month so far" + (plannedCents >= goal ? ", which meets your \(usd(goal)) goal." : ", \(usd(goal - plannedCents)) short of your \(usd(goal)) goal."), .init(jump: .budget, label: "Review plan"))
            }
            return say("You could save \(usd(total)) a month with rent unchanged. Biggest wins: \(top.joined(separator: " and ")). Swipe through the ideas to build your plan.", .init(jump: .budget, label: "Review ideas"))
        }
        if has("worth", "net", "assets", "debt") {
            return say("Your net worth is \(usd(v.netWorthCents)): \(usd(v.assetsCents)) you own minus \(usd(v.liabilitiesCents)) you owe, as of \(DemoStore.day(store.dataset.asOf)).", .init(jump: .accounts, label: "See accounts"))
        }
        if has("account", "connect", "bank", "card", "loan", "balance") {
            return say("\(v.accounts.count) accounts are connected across \(Set(v.accounts.map(\.institution)).count) institutions, all demo data synced \(DemoStore.day(store.dataset.asOf)).", .init(jump: .accounts, label: "Open accounts"))
        }
        if has("where", "spend", "spent", "go", "month", "money", "income") {
            let big = v.categories.first
            return say("In \(month) you kept \(usd(stays)) of \(usd(f.netIncomeCents)). \(big?.category ?? "Rent") was the biggest cost at \(usd(big?.totalCents ?? 0)).", .init(jump: .money, label: "Open \(month)"))
        }
        if has("hi", "hey", "hello", "thanks") { return say("Hi! Try asking where your money went or who owes you.") }
        return say("In this preview I can answer about spending, net worth, your plan, the dinner split and connected accounts. On iPhone, the on-device model handles open questions.")
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.title; configuration.icon.font(.caption2.weight(.bold)) } }
}

/// Lana's mark: the one gradient in the app, on the dock orb and the chat header.
struct LanaOrb: View {
    var size: CGFloat = 56
    var symbol = "sparkles"
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .background {
                Circle().fill(Theme.lanaGradient)
                    .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.45), .clear], center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0, endRadius: size * 0.55)))
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }
}

private struct TypingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.ink3).frame(width: 7, height: 7).opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { on = true }
        .accessibilityLabel("Lana is typing")
    }
}
