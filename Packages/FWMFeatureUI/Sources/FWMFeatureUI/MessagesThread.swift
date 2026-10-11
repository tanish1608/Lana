import SwiftUI
import FWMCore

/// Which Messages request a screen came from.
enum MessagesThreadKind: String, Identifiable { case money, budget, split; var id: String { rawValue } }

/// The Lana line in Messages. The host supplies the number (Info.plist key `LanaMessagesNumber`, set from the
/// relay's line number); nothing is hard-coded here, so a build without it falls back to the preview sheet.
enum LanaMessagesLine {
    nonisolated static func url(infoValue: Any? = Bundle.main.object(forInfoDictionaryKey: "LanaMessagesNumber")) -> URL? {
        guard let raw = infoValue as? String else { return nil }
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 7, digits.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return URL(string: "sms:\(digits)")
    }
}

/// The quoted request, as a button: opens the Lana thread in Messages, or a preview of it when Messages
/// can't be opened (no line number configured, or the simulator).
struct AskChip: View {
    let question: String
    let kind: MessagesThreadKind
    let store: DemoStore
    @State private var preview: MessagesThreadKind?
    @Environment(\.openURL) private var openURL

    init(_ question: String, kind: MessagesThreadKind, store: DemoStore) { self.question = question; self.kind = kind; self.store = store }

    var body: some View {
        Button {
            guard let url = LanaMessagesLine.url() else { preview = kind; return }
            openURL(url) { accepted in if !accepted { preview = kind } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "message.fill")
                Text(question).lineLimit(1)
                Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).opacity(0.7)
            }
            .font(.footnote.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(Theme.accent).background(Theme.accentSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.auraViolet.opacity(0.35)], startPoint: .leading, endPoint: .trailing), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Asked in Messages: \(question)").accessibilityHint("Opens your Lana conversation in Messages")
        .sheet(item: $preview) { MessagesThreadPreview(kind: $0, question: question, store: store) }
    }
}

/// A look at the Lana thread this screen came from. Numbers come from the engines; nothing is sent.
struct MessagesThreadPreview: View {
    let kind: MessagesThreadKind
    let question: String
    let store: DemoStore
    @Environment(\.dismiss) private var dismiss

    private struct Thread { var mine: [String]; var attachment: String?; var reply: String; var title: String }

    private var thread: Thread {
        let period = store.snapshotPeriod, month = DemoStore.monthName(period).components(separatedBy: " ").first ?? ""
        let view = try? store.moneyView(period).get()
        switch kind {
        case .money:
            guard let v = view else { return Thread(mine: [question], reply: "I couldn’t load your money just now.", title: "\(month) breakdown") }
            let f = v.flow, stays = f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents
            let top = v.categories.prefix(2).map { "\($0.category.lowercased()) at \(usd($0.totalCents))" }
            return Thread(mine: [question], reply: "You kept \(usd(stays)) of \(usd(f.netIncomeCents)). Your biggest costs were \(top.joined(separator: ", then ")).", title: "\(month) breakdown")
        case .budget:
            let all = PreviewBudgetPlan.swaps.map(\.savingsCents) + PreviewBudgetPlan.habits.map(\.savingsCents)
            let rent = view?.categories.first { $0.category == "Rent" }?.totalCents ?? 0
            return Thread(mine: [question], reply: "I found \(all.count) ideas worth up to \(usd(all.reduce(0, +))) a month, and rent stays at \(usd(rent)). I left out instant coffee since you’ve passed on it before.", title: "\(PreviewBudgetPlan.period) plan")
        case .split:
            let rq = store.unpaidRequests([:])
            let reply = rq.isEmpty ? "Send me the receipt and I’ll split it."
                : "You’re owed \(usd(rq.reduce(0) { $0 + $1.amountCents }, cents: true)): \(rq.map { "\($0.reviewedName) \(usd($0.amountCents, cents: true))" }.joined(separator: ", ")). Review before anything is sent."
            return Thread(mine: [question], attachment: "Receipt photo", reply: reply, title: "Dinner at \(store.dataset.receipts?.first?.merchant ?? "the restaurant")")
        }
    }

    var body: some View {
        let t = thread
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LanaMark(size: 34)
                VStack(alignment: .leading, spacing: 1) { Text("Lana").font(.headline); Text("iMessage · Today").font(.caption).foregroundStyle(Theme.ink2) }
                Spacer()
            }
            .padding(.bottom, 4)
            ForEach(t.mine, id: \.self) { bubble($0, mine: true) }
            if let a = t.attachment {
                HStack { Spacer(minLength: 50)
                    Label(a, systemImage: "paperclip").font(.subheadline).padding(.horizontal, 13).padding(.vertical, 9)
                        .foregroundStyle(.white).background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            }
            bubble(t.reply, mine: false)
            Button { dismiss() } label: {
                HStack(spacing: 10) {
                    LanaMark(size: 30)
                    VStack(alignment: .leading, spacing: 1) { Text(t.title).font(.subheadline.weight(.semibold)); Text("Open in Lana").font(.caption).foregroundStyle(Theme.ink2) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3)
                }
                .padding(12).frame(maxWidth: 280, alignment: .leading).foregroundStyle(Theme.ink)
                .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            SimulatedNote("Simulated. On iPhone this opens your Lana conversation in Messages.").padding(.top, 4)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .presentationDetents([.fraction(0.72), .large]).presentationDragIndicator(.visible)
        .presentationBackground(Theme.sheet) // solid, so the thread reads clearly
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 50) }
            Text(text).font(.subheadline).padding(.horizontal, 13).padding(.vertical, 9)
                .foregroundStyle(mine ? .white : Theme.ink)
                .background(mine ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.bubbleIn), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }
}
