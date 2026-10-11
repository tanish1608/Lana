import SwiftUI
import FWMCore

/// One account: balance, where the data came from, and its recent transactions from the session dataset.
struct AccountDetailView: View {
    let dataset: Dataset
    let period: String
    let accountID: String
    var onRemove: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var showAll = false

    private var account: Account? { dataset.accounts.first { $0.accountId == accountID } }
    private var balance: AccountBalance? { (try? MoneyEngine.moneyView(dataset, period: period, accountFilter: [accountID]))?.accounts.first }
    private var transactions: [FWMCore.Transaction] {
        dataset.transactions.filter { $0.accountId == accountID }.sorted { ($0.postedAt, $0.transactionId) > ($1.postedAt, $1.transactionId) }
    }

    var body: some View {
        ScrollView {
            if let account {
                let d = AccountDisplay(account)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 10) {
                        InstitutionLogo(name: account.institution, size: 64).shadow(color: d.color.opacity(0.3), radius: 12, y: 6)
                        Text(d.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                        Text("\(account.institution) · \(d.subtitle)").font(.subheadline).foregroundStyle(Theme.ink2)
                        HeroAmount(cents: account.balanceCents, size: 44).padding(.top, 4)
                        Text(account.assetOrLiability == .liability ? "Amount owed" : "Current balance").font(.footnote).foregroundStyle(Theme.ink2)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).raised(24)

                    SectionLabel("Details")
                    Card {
                        row("Source", d.isImported ? d.originLabel : "Sample data (\(dataset.dataMode.rawValue))")
                        Divider()
                        row("Balance as of", DemoStore.day(account.asOf))
                        if let open = account.openingBalanceCents, account.assetOrLiability == .asset {
                            Divider()
                            row("Change in \(DemoStore.monthName(period, short: true))", usd(account.balanceCents - open, cents: true, plus: true))
                        }
                        if let ok = balance?.reconciled {
                            Divider()
                            row("Balance check", ok ? "Matches activity" : "Doesn’t match activity", tone: ok ? Theme.ok : Theme.warn)
                        }
                    }

                    SectionLabel("Transactions")
                    Card {
                        if transactions.isEmpty {
                            Text("No transactions in this account’s data.").font(.subheadline).foregroundStyle(Theme.ink3)
                        }
                        ForEach(Array(transactions.prefix(showAll ? transactions.count : 12).enumerated()), id: \.element.transactionId) { n, t in
                            if n > 0 { Divider() }
                            TransactionRow(transaction: t)
                        }
                        if transactions.count > 12 && !showAll {
                            Button("Show all \(transactions.count)") { withAnimation { showAll = true } }.buttonStyle(GhostButtonStyle())
                        }
                    }

                    if d.isImported {
                        Button("Remove account", role: .destructive) { confirmRemove = true }
                            .buttonStyle(GhostButtonStyle()).tint(Theme.bad).frame(maxWidth: .infinity).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            } else {
                Text("This account is no longer connected.").foregroundStyle(Theme.ink2).padding(.top, 60)
            }
        }
        .scrollIndicators(.hidden).background { Theme.backdrop }
        .navigationTitle(account.map { AccountDisplay($0).title } ?? "Account")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Remove this account from Lana?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) { onRemove(accountID); dismiss() }
        } message: {
            Text("Its imported transactions are removed from this session. Nothing changes at \(account?.institution ?? "the institution").")
        }
    }

    private func row(_ label: String, _ value: String, tone: Color = Theme.ink) -> some View {
        HStack { Text(label).foregroundStyle(Theme.ink2); Spacer(); Text(value).fontWeight(.semibold).foregroundStyle(tone).multilineTextAlignment(.trailing) }
            .font(.subheadline).monospacedDigit()
    }
}
