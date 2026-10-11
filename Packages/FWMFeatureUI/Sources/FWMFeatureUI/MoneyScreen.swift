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

    var body: some View {
        NavigationStack {
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
            .background(Theme.bg)
            .navigationTitle("Money")
            .toolbar { DemoDataBadge() }
        }
    }

    private var periodPicker: some View {
        Picker("Month", selection: $period) {
            ForEach(store.periods, id: \.self) { Text(DemoStore.monthName($0, short: true)).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var inProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(DemoStore.monthName(period).components(separatedBy: " ").first ?? "") so far").font(Theme.display(30))
            Text("The month is still open, so nothing here is estimated.").foregroundStyle(Theme.ink2)
            periodPicker
            Card {
                Text("No posted totals yet").font(Theme.display(24))
                Text("Lana charts the month once its transactions post. The Oct 11 dinner receipt is tracked in Split and never changes September.")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
            }
        }
    }

    @ViewBuilder private func content(_ v: MoneyView) -> some View {
        let f = v.flow
        let stays = f.toSavingsCents + f.toInvestmentsCents + f.retainedCashCents
        let month = DemoStore.monthName(period).components(separatedBy: " ").first ?? period
        let biggest = v.categories.first
        MessagePreview(question: "Where did my money go in \(month)?",
                       answer: "In \(month) you brought in \(usd(f.netIncomeCents)) and spent \(usd(f.expensesCents)). \(biggest?.category ?? "Rent") was the biggest cost at \(usd(biggest?.totalCents ?? 0)). You moved \(usd(f.toSavingsCents)) to savings and \(usd(f.toInvestmentsCents)) to investing, and \(usd(f.retainedCashCents)) stayed in checking.")
        Text("\(usd(stays)) stayed with you").font(Theme.display(32)).padding(.top, 6)
        Text("\(usd(f.netIncomeCents)) came in during \(DemoStore.monthName(period)). \(usd(f.expensesCents)) went to expenses.")
            .foregroundStyle(Theme.ink2)
        periodPicker
        Picker("View", selection: $showBalances) { Text("Money in & out").tag(false); Text("Where it sits").tag(true) }
            .pickerStyle(.segmented)
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
                    .init(label: "Expenses", cents: f.expensesCents, color: Theme.goes),
                    .init(label: "Savings", cents: f.toSavingsCents, color: Theme.accent),
                    .init(label: "Investing", cents: f.toInvestmentsCents, color: Theme.accent2),
                    .init(label: "Kept in checking", cents: f.retainedCashCents, color: Theme.accent3),
                ], total: f.netIncomeCents)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Adds up", systemImage: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                Text("\(usd(f.netIncomeCents)) = \(usd(f.expensesCents)) spent + \(usd(f.toSavingsCents)) saved + \(usd(f.toInvestmentsCents)) invested + \(usd(f.retainedCashCents)) kept.")
                    .monospacedDigit()
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 20))

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
                row("Kept in checking", "Left in checking this month", f.retainedCashCents, Theme.accent3)
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
                Text("Net worth on \(DemoStore.day(store.dataset.asOf))").font(.caption).foregroundStyle(Theme.ink3)
                Text(usd(snap.netWorthCents)).font(Theme.display(44)).monospacedDigit()
                Text("\(usd(snap.assetsCents)) in assets minus \(usd(snap.liabilitiesCents)) owed").foregroundStyle(Theme.ink2)
            }
            SectionLabel("What you own")
            Card { ForEach(snap.accounts.filter { $0.assetOrLiability == .asset }, id: \.accountId) { accountRow($0) } }
            SectionLabel("What you owe")
            Card { ForEach(snap.accounts.filter { $0.assetOrLiability == .liability }, id: \.accountId) { accountRow($0) } }
            Text("Balances are a snapshot at the end of \(DemoStore.day(store.dataset.asOf)). Monthly income and spending are under Money in & out.")
                .font(.caption).foregroundStyle(Theme.ink3)
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
    let txs: [Transaction]
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
