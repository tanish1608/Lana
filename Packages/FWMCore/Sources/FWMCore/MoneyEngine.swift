import Foundation

// get_money_view (SRS v2 section 3). Deterministic: the model only narrates these numbers.

public struct MoneyFlow: Codable, Sendable, Equatable {
    public var netIncomeCents: Int
    public var expensesCents: Int
    public var toSavingsCents: Int
    public var toInvestmentsCents: Int
    /// Cash kept this month: income − expenses − savings − investments.
    public var retainedCashCents: Int
    /// Card repayments are shown for transparency but never counted as spending (MONEY-04).
    public var cardRepaymentCents: Int
}

public struct CategoryTotal: Codable, Sendable, Equatable {
    public var category: String
    public var totalCents: Int
    public var transactionIds: [String]
}

public struct AccountBalance: Codable, Sendable, Equatable {
    public var accountId: String
    public var institution: String
    public var kind: String
    public var assetOrLiability: Account.Side
    public var balanceCents: Int
    public var asOf: String
    public var sourceId: String?
    /// Opening balance + this period's posted activity == closing balance. Nil when no opening balance is known.
    public var reconciled: Bool?
}

public struct ExcludedTransaction: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable { case transferCounterpart, internalTransfer, cardRepayment, unmatchedTransfer, pending }
    public var transactionId: String
    public var reason: Reason
}

public struct MoneyView: Codable, Sendable, Equatable {
    public var provenance: Provenance
    public var period: String
    public var flow: MoneyFlow
    public var categories: [CategoryTotal]
    public var accounts: [AccountBalance]
    public var assetsCents: Int
    public var liabilitiesCents: Int
    public var netWorthCents: Int
    public var pendingCents: Int
    public var excluded: [ExcludedTransaction]
    /// True when category totals equal expenses and every account with an opening balance reconciles.
    public var reconciled: Bool
}

public enum MoneyEngine {
    public static let version = "money-1.0"

    public static func moneyView(_ ds: Dataset, period: String, accountFilter: [String]? = nil) throws -> MoneyView {
        guard ToolCall.isPeriod(period) else { throw ToolError(.invalidArguments, "Which month? For example 2026-09.") }
        let tz = TimeZone(identifier: ds.user.timezone) ?? TimeZone(identifier: "America/Los_Angeles")!
        let accounts = ds.accounts.filter { accountFilter == nil || accountFilter!.contains($0.accountId) }
        let byId = Dictionary(uniqueKeysWithValues: ds.accounts.map { ($0.accountId, $0) })
        let inScope = Set(accounts.map(\.accountId))

        // DATA-03: dedupe by stable source id, keeping the last update.
        var seen: [String: Transaction] = [:]
        for t in ds.transactions { seen[t.sourceId ?? t.transactionId] = t }
        let all = seen.values.filter { monthKey($0.postedAt, tz) == period }.sorted { ($0.postedAt, $0.transactionId) < ($1.postedAt, $1.transactionId) }
        let byPair = Dictionary(grouping: all.filter { $0.transferPairId != nil }, by: { $0.transferPairId! })

        var flow = MoneyFlow(netIncomeCents: 0, expensesCents: 0, toSavingsCents: 0, toInvestmentsCents: 0, retainedCashCents: 0, cardRepaymentCents: 0)
        var cats: [String: (Int, [String])] = [:]
        var excluded: [ExcludedTransaction] = []
        var pendingCents = 0
        var sources: [String] = []

        for t in all where inScope.contains(t.accountId) {
            sources.append(t.sourceId ?? t.transactionId)
            if t.pending {
                pendingCents += -t.signedAmountCents
                excluded.append(.init(transactionId: t.transactionId, reason: .pending))
                continue
            }
            if let pair = t.transferPairId {
                let other = byPair[pair]?.first { $0.transactionId != t.transactionId && $0.accountId != t.accountId }
                guard let other, let otherAcct = byId[other.accountId] else {
                    excluded.append(.init(transactionId: t.transactionId, reason: .unmatchedTransfer))
                    continue
                }
                // Count each matched transfer once, on its outflow side.
                guard t.signedAmountCents < 0 else {
                    excluded.append(.init(transactionId: t.transactionId, reason: .transferCounterpart))
                    continue
                }
                let amount = -t.signedAmountCents
                switch (otherAcct.assetOrLiability, otherAcct.kind) {
                case (.liability, _):
                    flow.cardRepaymentCents += amount
                    excluded.append(.init(transactionId: t.transactionId, reason: .cardRepayment))
                case (_, "savings"):
                    flow.toSavingsCents += amount
                case (_, "brokerage"), (_, "investment"), (_, "retirement"):
                    flow.toInvestmentsCents += amount
                default:
                    excluded.append(.init(transactionId: t.transactionId, reason: .internalTransfer))
                }
                continue
            }
            let category = (t.category?.isEmpty == false ? t.category! : "Uncategorized")
            if category == "Income" && t.signedAmountCents > 0 {
                flow.netIncomeCents += t.signedAmountCents
                continue
            }
            // Purchases are negative; refunds are positive and reduce their category (MONEY-04).
            var entry = cats[category] ?? (0, [])
            entry.0 += -t.signedAmountCents
            entry.1.append(t.transactionId)
            cats[category] = entry
            flow.expensesCents += -t.signedAmountCents
        }
        flow.retainedCashCents = flow.netIncomeCents - flow.expensesCents - flow.toSavingsCents - flow.toInvestmentsCents

        let balances = accounts.map { a -> AccountBalance in
            var ok: Bool? = nil
            if let open = a.openingBalanceCents {
                let activity = all.filter { $0.accountId == a.accountId && !$0.pending }.reduce(0) { $0 + $1.signedAmountCents }
                // Assets rise with inflows; amounts owed fall with inflows (payments, refunds).
                ok = (a.assetOrLiability == .asset ? open + activity : open - activity) == a.balanceCents
            }
            return AccountBalance(accountId: a.accountId, institution: a.institution, kind: a.kind, assetOrLiability: a.assetOrLiability,
                                  balanceCents: a.balanceCents, asOf: a.asOf, sourceId: a.sourceId, reconciled: ok)
        }
        let assets = accounts.filter { $0.assetOrLiability == .asset }.reduce(0) { $0 + $1.balanceCents }
        let liabilities = accounts.filter { $0.assetOrLiability == .liability }.reduce(0) { $0 + $1.balanceCents }
        let categories = cats.map { CategoryTotal(category: $0.key, totalCents: $0.value.0, transactionIds: $0.value.1) }
            .sorted { ($0.totalCents, $1.category) > ($1.totalCents, $0.category) }
        let reconciled = categories.reduce(0) { $0 + $1.totalCents } == flow.expensesCents && !balances.contains { $0.reconciled == false }

        let filterKey = accountFilter?.sorted().joined(separator: "+") ?? "all"
        let provenance = Provenance(resultId: "mv:\(ds.datasetVersion):\(period):\(filterKey)", datasetVersion: ds.datasetVersion,
                                    dataMode: ds.dataMode, asOf: ds.asOf, sourceIds: sources, engineVersion: version)
        return MoneyView(provenance: provenance, period: period, flow: flow, categories: categories, accounts: balances,
                         assetsCents: assets, liabilitiesCents: liabilities, netWorthCents: assets - liabilities,
                         pendingCents: pendingCents, excluded: excluded, reconciled: reconciled)
    }

    /// Calendar month of an ISO 8601 timestamp in the user's time zone (CORE-02).
    static func monthKey(_ iso: String, _ tz: TimeZone) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let date = f.date(from: iso) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }
}
