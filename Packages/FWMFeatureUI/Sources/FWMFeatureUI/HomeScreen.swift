import SwiftUI
import FWMCore

enum LanaTab: Hashable, CaseIterable { case home, budget, split, accounts }

/// Home: net worth and the month's money at a glance. Messages is the main interface; this app holds the details.
struct HomeScreen: View {
    let store: DemoStore
    @Binding var tab: LanaTab
    let requestStates: [String: RequestState]
    let budgetAdopted: Bool
    @Binding var path: NavigationPath
    var openChat: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if case .success(let v) = store.moneyView(store.snapshotPeriod) {
                        netWorth(v)
                        NavigationLink(value: HomeRoute.money) { ringCard(v) }.buttonStyle(PressScaleStyle())
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
            .navigationDestination(for: HomeRoute.self) { _ in MoneyScreen(store: store) }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let clock = store.dataset.demoClock { Text(DemoStore.weekday(clock)).font(.footnote).foregroundStyle(Theme.ink2) }
                Text("Hi, \(store.dataset.user.displayName ?? "there")").font(Theme.display(30))
            }
            Spacer()
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
        .background {
            LinearGradient(colors: [Theme.sky, Theme.skyDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topTrailing) { Circle().fill(.white.opacity(0.18)).frame(width: 220, height: 220).offset(x: 70, y: -110).blur(radius: 8) }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .raised(24, tint: Theme.accent, strength: 1.6)
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
        .raised(24)
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
                duoCard(fill: Theme.inkCard, ink: .white, glow: .black) {
                    Text(usd(owed.reduce(0) { $0 + $1.amountCents }, cents: true)).font(.system(size: 28, weight: .bold)).monospacedDigit().foregroundStyle(Theme.warn)
                    Text("owed to you").font(.footnote)
                    Text(owed.isEmpty ? "All settled" : owed.map(\.reviewedName).joined(separator: ", ")).font(.caption).opacity(0.6)
                }
            }
            Button { tab = .budget } label: {
                duoCard(fill: Theme.sky2, ink: Theme.skyInk, glow: Theme.accent) {
                    (Text(usd(plan)).font(.system(size: 28, weight: .bold)) + Text("/mo").font(.subheadline.weight(.semibold))).monospacedDigit().foregroundStyle(Theme.accent)
                    Text("plan to save").font(.footnote)
                    Text(budgetAdopted ? "Adopted" : "Ready to review").font(.caption).opacity(0.6)
                }
            }
        }
        .buttonStyle(PressScaleStyle())
    }

    private func duoCard<C: View>(fill: Color, ink: Color, glow: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) { Spacer(minLength: 0); content() }
            .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.8)
            .padding(18).frame(maxWidth: .infinity, minHeight: 132, alignment: .bottomLeading)
            .background(fill.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .raised(24, tint: glow, strength: 1.4)
    }

    private func latest(_ v: MoneyView) -> some View {
        let f = v.flow, stays = f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents
        let month = DemoStore.monthName(store.snapshotPeriod).components(separatedBy: " ").first ?? ""
        return Button { openChat() } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Eyebrow("Latest from Lana"); Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3) }
                Text("You kept \(usd(stays)) of \(usd(f.netIncomeCents)) in \(month). Want a plan to save $150 more?")
                    .font(.subheadline).multilineTextAlignment(.leading).padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .foregroundStyle(Theme.ink)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .raised(24)
        }
        .buttonStyle(PressScaleStyle())
    }
}

enum HomeRoute: Hashable { case money }
