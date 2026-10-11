import SwiftUI
import FWMCore

private let kindNames = ["checking": "Checking", "savings": "Savings", "brokerage": "Brokerage", "credit_card": "Credit card", "student_loan": "Student loan"]

/// Journey 1: where money went this month (flows) and where it sits (balances), from `get_money_view`.
struct MoneyScreen: View {
    let store: DemoStore
    @State private var period: String
    @State private var showBalances = false

    init(store: DemoStore) {
        self.store = store
        _period = State(initialValue: store.snapshotPeriod)
    }

    // Pushed from Home, so it uses Home's navigation stack.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch store.moneyView(period) {
                case .failure(let e): Card { Tag(text: "Couldn’t load", tone: Theme.bad); Text(e.userMessage) }
                case .success(let v):
                    if period > store.snapshotPeriod { inProgress } else { content(v) }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background { Theme.backdrop }
        .navigationTitle("Money")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { DemoDataBadge() }
    }

    private var periodPicker: some View {
        PillPicker(options: store.periods.map { ($0, DemoStore.monthName($0, short: true)) }, selection: $period)
    }

    private var inProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(DemoStore.monthName(period).components(separatedBy: " ").first ?? "") so far").font(Theme.display(30))
            periodPicker
            Card {
                Text("No posted totals yet").font(Theme.display(24))
                Text("Nothing is estimated. The Oct 11 dinner is in Split.").font(.subheadline).foregroundStyle(Theme.ink2)
            }
        }
    }

    @ViewBuilder private func content(_ v: MoneyView) -> some View {
        let f = v.flow
        let stays = f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents
        let month = DemoStore.monthName(period).components(separatedBy: " ").first ?? period
        AskChip("Where did my money go in \(month)?")
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Stayed with you · \(month)")
            HeroAmount(cents: stays)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        periodPicker
        PillPicker(options: [(false, "Money in & out"), (true, "Where it sits")], selection: $showBalances)
        if showBalances { balances } else { flows(v) }
    }

    @ViewBuilder private func flows(_ v: MoneyView) -> some View {
        let f = v.flow
        let flowOK = f.netIncomeCents == f.expensesCents + f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents
            && v.categories.reduce(0) { $0 + $1.totalCents } == f.expensesCents
        if !flowOK {
            Card { Tag(text: "Doesn’t reconcile", tone: Theme.bad); Text("These numbers don’t add up, so Lana won’t chart them.") }
        } else {
            Card {
                FlowBar(segments: [
                    .init(label: "Expenses", cents: f.expensesCents, color: Theme.spent),
                    .init(label: "Savings", cents: f.toSavingsCents, color: Theme.accent),
                    .init(label: "Investing", cents: f.toInvestmentsCents, color: Theme.accent2),
                    .init(label: "Kept in checking", cents: f.retainedCashCents, color: Theme.ok),
                ], total: f.netIncomeCents)
            }
            CheckLine("\(usd(f.netIncomeCents)) = \(usd(f.expensesCents)) + \(usd(f.toSavingsCents)) + \(usd(f.toInvestmentsCents)) + \(usd(f.retainedCashCents))")

            SectionLabel("Spending by category")
            Card {
                let maxC = v.categories.map(\.totalCents).max() ?? 1
                ForEach(v.categories, id: \.category) { c in
                    NavigationLink {
                        TransactionList(title: c.category, subtitle: DemoStore.monthName(period), txs: store.transactions(c.transactionIds), total: c.totalCents)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(c.category).fontWeight(.semibold); Spacer(); Text(usd(c.totalCents)).fontWeight(.semibold).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.ink3) }
                            GeometryReader { g in
                                Capsule().fill(Theme.line).overlay(alignment: .leading) {
                                    Capsule().fill(Theme.goes).frame(width: g.size.width * CGFloat(c.totalCents) / CGFloat(maxC))
                                }
                            }.frame(height: 6)
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                HStack { Text("Total spending").bold(); Spacer(); Text(usd(f.expensesCents)).bold().monospacedDigit() }
            }
            SectionLabel("Set aside, not spent")
            Card {
                row("To savings", "Transfer, not spending", f.toSavingsCents, Theme.accent)
                row("To investing", "Transfer, not spending", f.toInvestmentsCents, Theme.accent2)
                row("Kept in checking", "Left in checking this month", f.retainedCashCents, Theme.ok)
            }
            if v.pendingCents != 0 {
                Text("\(usd(v.pendingCents, cents: true)) pending, not included above.").font(.caption).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func row(_ t: String, _ s: String, _ c: Int, _ color: Color) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading) { Text(t).fontWeight(.semibold); Text(s).font(.caption).foregroundStyle(Theme.ink3) }
            Spacer()
            Text(usd(c)).fontWeight(.semibold).monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var balances: some View {
        if case .success(let snap) = store.moneyView(store.snapshotPeriod) {
            Card {
                Eyebrow("Net worth · \(DemoStore.day(store.dataset.asOf))")
                HeroAmount(cents: snap.netWorthCents, size: 44)
                Text("\(usd(snap.assetsCents)) owned − \(usd(snap.liabilitiesCents)) owed").font(.footnote).foregroundStyle(Theme.ink2).monospacedDigit()
            }
            SectionLabel("What you own")
            Card { ForEach(snap.accounts.filter { $0.assetOrLiability == .asset }, id: \.accountId) { accountRow($0) } }
            SectionLabel("What you owe")
            Card { ForEach(snap.accounts.filter { $0.assetOrLiability == .liability }, id: \.accountId) { accountRow($0) } }
            Text("Snapshot at the end of \(DemoStore.day(store.dataset.asOf)).").font(.caption).foregroundStyle(Theme.ink3).padding(.horizontal, 4)
        }
    }

    private func accountRow(_ a: AccountBalance) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(kindNames[a.kind] ?? a.kind).fontWeight(.semibold)
                HStack(spacing: 6) {
                    Text("\(a.institution) · updated \(DemoStore.day(a.asOf))").font(.caption).foregroundStyle(Theme.ink3)
                    if a.reconciled == true { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(Theme.accent).accessibilityLabel("Reconciled") }
                }
            }
            Spacer()
            Text(usd(a.balanceCents)).fontWeight(.semibold).monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

/// Proportional bar of where income went, with readable labels below instead of on tiny segments.
struct FlowBar: View {
    struct Segment: Identifiable { var id: String { label }; let label: String; let cents: Int; let color: Color }
    let segments: [Segment]
    let total: Int
    @State private var grown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where \(usd(total)) went").font(.subheadline.weight(.semibold))
            GeometryReader { g in
                HStack(spacing: 3) {
                    ForEach(segments) { s in
                        RoundedRectangle(cornerRadius: 5).fill(s.color)
                            .frame(width: max(4, (g.size.width - 9) * CGFloat(s.cents) / CGFloat(max(total, 1)) * (grown ? 1 : 0.02)))
                    }
                }
            }
            .frame(height: 28)
            .onAppear { withAnimation(.spring(duration: 0.8)) { grown = true } }
            .accessibilityElement().accessibilityLabel(segments.map { "\($0.label) \(usd($0.cents))" }.joined(separator: ", "))
            ForEach(segments) { s in
                HStack { RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 10, height: 10); Text(s.label); Spacer(); Text(usd(s.cents)).fontWeight(.semibold).monospacedDigit() }
                    .font(.subheadline)
            }
        }
    }
}

struct TransactionList: View {
    let title: String
    let subtitle: String
    let txs: [FWMCore.Transaction]
    let total: Int
    var body: some View {
        List {
            Section(subtitle) {
                ForEach(txs, id: \.transactionId) { t in
                    HStack { VStack(alignment: .leading) { Text(t.merchant); Text(DemoStore.day(t.postedAt)).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(usd(abs(t.signedAmountCents), cents: true)).monospacedDigit() }
                }
            }
            Section { HStack { Text("Total").bold(); Spacer(); Text(usd(total, cents: true)).bold().monospacedDigit() } }
        }
        .scrollContentBackground(.hidden).background { Theme.backdrop }
        .navigationTitle(title)
    }
}

struct DemoDataBadge: View {
    var body: some View {
        Text("Demo data").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(Theme.warn).background(Theme.warnSoft, in: Capsule())
            .accessibilityLabel("Synthetic demo data")
    }
}
