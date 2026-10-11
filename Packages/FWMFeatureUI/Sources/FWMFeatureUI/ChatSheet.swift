import SwiftUI
import FWMCore

struct ChatMessage: Identifiable, Equatable {
    enum Jump: Equatable { case money, budget, split, accounts }
    let id = UUID()
    let mine: Bool
    let text: String
    var jump: Jump?
}

/// Talk to Lana inside the app. In this fixture build the replies are scripted from engine results
/// (MoneyEngine, SplitEngine); the on-device model plugs in behind `reply(to:)`.
struct ChatSheet: View {
    let store: DemoStore
    @Binding var messages: [ChatMessage]
    var onJump: (ChatMessage.Jump) -> Void
    @State private var draft = ""
    @State private var thinking = false
    @FocusState private var focused: Bool

    private static let suggestions = ["Where did my money go?", "What’s my net worth?", "Save $150 next month", "Split dinner"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(messages) { bubble($0) }
                        if thinking { HStack { TypingDots(); Spacer() } }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                }
                .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: thinking) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { send(s) }.font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 34)
                            .foregroundStyle(Theme.accent).background(Theme.accentSoft, in: Capsule())
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                TextField("Ask Lana", text: $draft).focused($focused).submitLabel(.send).onSubmit { send(draft) }
                    .padding(.horizontal, 16).frame(minHeight: 44).background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.edge))
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Theme.lanaGradient, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityLabel("Send")
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(Theme.bg)
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LanaOrb(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lana").font(.headline)
                SimulatedNote("Scripted demo replies")
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 10)
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack(alignment: .bottom) {
            if m.mine { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 8) {
                Text(m.text).font(.subheadline)
                if let j = m.jump {
                    Button { onJump(j) } label: {
                        Label(Self.jumpLabel(j), systemImage: "arrow.up.right").font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 32).foregroundStyle(.white).background(Theme.accent, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(m.mine ? .white : Theme.ink)
            .background(m.mine ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.bubbleIn), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !m.mine { Spacer(minLength: 40) }
        }
    }

    private static func jumpLabel(_ j: ChatMessage.Jump) -> String {
        switch j { case .money: return "Open Money"; case .budget: return "Open Budget"; case .split: return "Open Split"; case .accounts: return "Open Accounts" }
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        draft = ""
        messages.append(ChatMessage(mine: true, text: text))
        thinking = true
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            messages.append(Self.reply(to: text, store: store))
            thinking = false
        }
    }

    /// Scripted intent match. Every number comes from the engines, never from this file.
    static func reply(to text: String, store: DemoStore) -> ChatMessage {
        let q = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { q.contains($0) } }
        guard case .success(let v) = store.moneyView(store.snapshotPeriod) else {
            return ChatMessage(mine: false, text: "I couldn’t load your money just now.")
        }
        let f = v.flow, month = DemoStore.monthName(store.snapshotPeriod).components(separatedBy: " ").first ?? ""
        if has("split", "dinner", "receipt", "tanish", "aryan", "owed to me") {
            guard let s = store.fixtureSplit() else { return ChatMessage(mine: false, text: "Send me a receipt and I’ll split it.", jump: .split) }
            let parts = s.requests.map { "\($0.reviewedName) \(usd($0.amountCents, cents: true))" }.joined(separator: ", ")
            return ChatMessage(mine: false, text: "From the dinner receipt you’re owed \(usd(s.outstandingCents, cents: true)): \(parts). Review before anything is sent.", jump: .split)
        }
        if has("save", "budget", "150", "cut", "swap") {
            let swaps = PreviewBudgetPlan.swaps.reduce(0) { $0 + $1.savingsCents }, habits = PreviewBudgetPlan.habits.reduce(0) { $0 + $1.savingsCents }
            return ChatMessage(mine: false, text: "I can free up \(usd(swaps + habits)) a month with rent unchanged: \(PreviewBudgetPlan.swaps.count) swaps worth \(usd(swaps)) and \(PreviewBudgetPlan.habits.count) habits worth \(usd(habits)).", jump: .budget)
        }
        if has("account", "connected", "bank", "linked") {
            let names = Set(v.accounts.map(\.institution)).count
            return ChatMessage(mine: false, text: "\(v.accounts.count) accounts are connected across \(names) institutions.", jump: .accounts)
        }
        if has("net worth", "worth", "owe", "debt", "balance", "assets") {
            return ChatMessage(mine: false, text: "Your net worth is \(usd(v.netWorthCents)): \(usd(v.assetsCents)) owned and \(usd(v.liabilitiesCents)) owed.", jump: .money)
        }
        if has("where", "spend", "spent", "money", "month", "go") {
            let top = v.categories.first
            return ChatMessage(mine: false, text: "In \(month) \(usd(f.netIncomeCents)) came in and \(usd(f.expensesCents)) went out. \(top?.category ?? "Rent") was biggest at \(usd(top?.totalCents ?? 0)). \(usd(f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents)) stayed with you.", jump: .money)
        }
        return ChatMessage(mine: false, text: "In this demo I can answer about spending, net worth, a savings plan, your accounts, or splitting a bill.")
    }
}

/// Lana's mark: the one gradient in the app, reused on the dock button and chat header.
struct LanaOrb: View {
    var size: CGFloat = 56
    var body: some View {
        Image(systemName: "sparkles").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.lanaGradient, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
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
