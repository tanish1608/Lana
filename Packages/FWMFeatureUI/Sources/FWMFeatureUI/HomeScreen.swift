import SwiftUI
import FWMCore

enum LanaTab: Hashable { case home, budget, split, vault }

/// Home: net worth and the month's money at a glance. Messages is the main interface; this app holds the details.
struct HomeScreen: View {
    let store: DemoStore
    @Binding var tab: LanaTab
    let requestStates: [String: RequestState]
    let budgetAdopted: Bool
    @State private var showMessages = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if case .success(let v) = store.moneyView(store.snapshotPeriod) {
                        netWorth(v)
                        NavigationLink { MoneyScreen(store: store) } label: { ringCard(v) }.buttonStyle(PressScaleStyle())
                        duo
                        latest(v)
                    } else {
                        Card { Text("Couldn’t load your money.") }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar { DemoDataBadge() }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showMessages) { messagesSheet }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let clock = store.dataset.demoClock { Text(DemoStore.weekday(clock)).font(.footnote).foregroundStyle(Theme.ink2) }
                Text("Hi, \(store.dataset.user.displayName ?? "there")").font(Theme.display(30))
            }
            Spacer()
            Button { showMessages = true } label: {
                Label("Messages", systemImage: "message.fill").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(minHeight: 40).foregroundStyle(.white).background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
    }

    private func netWorth(_ v: MoneyView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Net worth").font(.footnote.weight(.semibold)).opacity(0.7)
            HeroAmount(cents: v.netWorthCents).padding(.top, 8).padding(.bottom, 16)
            GeometryReader { g in
                let owned = (g.size.width - 4) * CGFloat(v.assetsCents) / CGFloat(max(v.assetsCents + v.liabilitiesCents, 1))
                HStack(spacing: 4) {
                    Capsule().fill(Theme.skyInk).frame(width: owned)
                    Capsule().fill(Theme.skyInk.opacity(0.25))
                }
            }
            .frame(height: 10).padding(.bottom, 10)
            HStack {
                Text(usd(v.assetsCents)).bold() + Text(" owned")
                Spacer()
                Text(usd(v.liabilitiesCents)).bold() + Text(" owed")
            }
            .font(.footnote).monospacedDigit()
        }
        .foregroundStyle(Theme.skyInk)
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sky, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func ringCard(_ v: MoneyView) -> some View {
        let f = v.flow
        let parts: [RingChart<AnyView>.Segment] = [
            .init(label: "Spent", cents: f.expensesCents, color: Theme.spent),
            .init(label: "Saved", cents: f.toSavingsCents, color: Theme.accent),
            .init(label: "Invested", cents: f.toInvestmentsCents, color: Theme.accent2),
            .init(label: "Kept", cents: f.retainedCashCents, color: Theme.ok),
        ]
        let stays = f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents
        return VStack(spacing: 12) {
            HStack { Eyebrow(DemoStore.monthName(store.snapshotPeriod).components(separatedBy: " ").first ?? ""); Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3) }
            RingChart(segments: parts, total: f.netIncomeCents) {
                AnyView(VStack(spacing: 0) {
                    Text("Stayed").font(.footnote).foregroundStyle(Theme.ink2)
                    Text(usd(stays)).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    Text("of \(usd(f.netIncomeCents))").font(.footnote).foregroundStyle(Theme.ink2)
                })
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(parts) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) { Circle().fill(p.color).frame(width: 10, height: 10); Text(p.label).font(.footnote).foregroundStyle(Theme.ink2) }
                        Text(usd(p.cents)).font(.system(size: 20, weight: .bold)).monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(18).background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var unpaid: [ReimbursementDraft] {
        (store.fixtureSplit()?.requests ?? []).filter {
            let s = requestStates[$0.contactId] ?? .draft
            return s != .paidReported && s != .cancelled
        }
    }

    private var duo: some View {
        let owed = unpaid
        let plan = PreviewBudgetPlan.swaps.reduce(0) { $0 + $1.savingsCents } + PreviewBudgetPlan.habits.reduce(0) { $0 + $1.savingsCents }
        return HStack(spacing: 12) {
            Button { tab = .split } label: {
                duoCard(fill: Theme.inkCard, ink: .white) {
                    Text(usd(owed.reduce(0) { $0 + $1.amountCents }, cents: true)).font(.system(size: 28, weight: .bold)).monospacedDigit().foregroundStyle(Theme.warn)
                    Text("owed to you").font(.footnote)
                    Text(owed.isEmpty ? "All settled" : owed.map(\.reviewedName).joined(separator: ", ")).font(.caption).opacity(0.6)
                }
            }
            Button { tab = .budget } label: {
                duoCard(fill: Theme.sky2, ink: Theme.skyInk) {
                    (Text(usd(plan)).font(.system(size: 28, weight: .bold)) + Text("/mo").font(.subheadline.weight(.semibold))).monospacedDigit().foregroundStyle(Theme.accent)
                    Text("plan to save").font(.footnote)
                    Text(budgetAdopted ? "Adopted" : "Ready to review").font(.caption).opacity(0.6)
                }
            }
        }
        .buttonStyle(PressScaleStyle())
    }

    private func duoCard<C: View>(fill: Color, ink: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) { Spacer(minLength: 0); content() }
            .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.8)
            .padding(18).frame(maxWidth: .infinity, minHeight: 132, alignment: .bottomLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func latest(_ v: MoneyView) -> some View {
        let f = v.flow, stays = f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents
        let month = DemoStore.monthName(store.snapshotPeriod).components(separatedBy: " ").first ?? ""
        return Button { showMessages = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Eyebrow("Latest in Messages"); Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3) }
                Text("You kept \(usd(stays)) of \(usd(f.netIncomeCents)) in \(month). Want a plan to save $150 more?")
                    .font(.subheadline).multilineTextAlignment(.leading).padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .foregroundStyle(Theme.ink)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }

    private var messagesSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lana lives in Messages").font(.title2.bold()).padding(.bottom, 4)
            bubble("Where did my money go this month?", mine: true)
            bubble("You kept $1,650 of $4,800 in September. Rent was the biggest cost.", mine: false)
            bubble("Split dinner with Tanish and Aryan", mine: true)
            bubble("You’re owed $80.60. Review the requests?", mine: false)
            SimulatedNote("Preview only").padding(.top, 4)
            Spacer(minLength: 0)
            Button("Done") { showMessages = false }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .presentationDetents([.fraction(0.62), .large])
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 50) }
            Text(text).font(.subheadline).padding(.horizontal, 13).padding(.vertical, 9)
                .foregroundStyle(mine ? .white : Theme.ink)
                .background(mine ? Theme.accent : Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }
}
