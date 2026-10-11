import XCTest
@testable import FWMCore

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")

/// Writes each account as a bank-style CSV export: no ids, no transfer links, US dates on the card account.
private func exportStatements(_ ds: Dataset) -> [CSVStatement] {
    ds.accounts.map { a in
        let rows = ds.transactions.filter { $0.accountId == a.accountId }.sorted { $0.postedAt < $1.postedAt }.map { t -> String in
            let day = String(t.postedAt.prefix(10))
            let date = a.kind == "credit_card" ? "\(day.dropFirst(5).prefix(2))/\(day.suffix(2))/\(day.prefix(4))" : day
            let amount = String(format: "%.2f", Double(t.signedAmountCents) / 100)
            return "\(date),\"\(t.merchant)\",\(amount),\(t.category ?? ""),\(t.pending ? "Pending" : "Posted")"
        }
        return CSVStatement(accountId: a.accountId, institution: a.institution, kind: a.kind, side: a.assetOrLiability,
                            balanceCents: a.balanceCents, csv: (["Date,Description,Amount,Category,Status"] + rows).joined(separator: "\n"))
    }
}

final class ProviderTests: XCTestCase {
    /// The canonical month, round-tripped through bank exports that lost every transfer link, gives the SRS numbers.
    func testCSVImportReproducesSeptember() throws {
        let seed = try Dataset.load(from: fixtures.appendingPathComponent("seed-v1.json"))
        let (ds, status) = try BankCSVProvider(statements: exportStatements(seed), user: seed.user, asOf: seed.asOf).fetch()
        XCTAssertEqual(status.transactionCount, seed.transactions.count)
        XCTAssertEqual(status.matchedTransfers, Set(seed.transactions.compactMap(\.transferPairId)).count)
        XCTAssertEqual(status.warnings, [])
        XCTAssertEqual(ds.dataMode, .live)

        let v = try MoneyEngine.moneyView(ds, period: "2026-09")
        XCTAssertEqual([v.flow.netIncomeCents, v.flow.expensesCents, v.flow.toSavingsCents, v.flow.toInvestmentsCents, v.flow.retainedCashCents],
                       [480_000, 315_000, 65_000, 40_000, 60_000])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: v.categories.map { ($0.category, $0.totalCents) }),
                       ["Rent": 160_000, "Groceries": 50_000, "Dining": 30_000, "Transport": 25_000, "Bills and subscriptions": 25_000, "Other": 25_000])
        XCTAssertEqual(v.netWorthCents, 1_155_000)
        XCTAssertTrue(v.provenance.sourceIds.allSatisfy { $0.hasPrefix("csv:") })
    }

    /// Card repayment, savings transfer, refund and pending survive the export with no links, and match the edge fixture's expected values.
    func testCSVImportHandlesEdgeCases() throws {
        let edge = try Dataset.load(from: fixtures.appendingPathComponent("edge-v1.json"))
        let (ds, status) = try BankCSVProvider(statements: exportStatements(edge), user: edge.user, asOf: edge.asOf).fetch()
        XCTAssertEqual(status.matchedTransfers, 2)
        let v = try MoneyEngine.moneyView(ds, period: String(edge.asOf.prefix(7)))
        XCTAssertEqual(v.flow.netIncomeCents, 50_000)
        XCTAssertEqual(v.flow.expensesCents, 18_000)
        XCTAssertEqual(v.flow.toSavingsCents, 10_000)
        XCTAssertEqual(v.flow.cardRepaymentCents, 27_000)
        XCTAssertEqual(v.pendingCents, 6_500)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: v.categories.map { ($0.category, $0.totalCents) }), ["Other": 9_000, "Groceries": 9_000])
    }

    func testMessyExportAndUnmatchedTransfer() throws {
        let csv = """
        Posting Date,Payee,Amount,Category
        09/02/2026,"Blue Bottle, Mint Plaza",($6.50),Dining
        09/03/2026,Acme payroll,"$2,400.00",Income
        09/05/2026,Transfer to Ally savings,-300.00,Transfer
        09/05/2026,Blue Bottle,-6.50,Dining
        09/05/2026,Blue Bottle,-6.50,Dining
        not a date,???,abc,Other
        """
        let user = UserPrefs(userId: "u", displayName: nil, timezone: "America/Los_Angeles", currency: "USD", brandLocks: [], dietaryRules: [],
                             savingsGoalCents: 0, preferencesVersion: 1)
        let st = CSVStatement(accountId: "chk", institution: "Bank", kind: "checking", side: .asset, balanceCents: 100_000, csv: csv)
        let (ds, status) = try BankCSVProvider(statements: [st], user: user, asOf: "2026-09-30T23:59:59-07:00").fetch()
        XCTAssertEqual(ds.transactions.map(\.signedAmountCents), [-650, 240_000, -30_000, -650, -650])
        XCTAssertEqual(ds.transactions[0].merchant, "Blue Bottle, Mint Plaza")
        XCTAssertEqual(Set(ds.transactions.map(\.transactionId)).count, 5, "identical rows keep distinct ids")
        XCTAssertEqual(status.matchedTransfers, 0)
        XCTAssertEqual(status.warnings.count, 2) // the unreadable row and the transfer with no savings account imported
        let v = try MoneyEngine.moneyView(ds, period: "2026-09")
        XCTAssertEqual(v.flow.expensesCents, 1_950, "an unmatched transfer is not spending")

        // Re-importing the same export yields the same ids, so the engine's source-id dedupe holds.
        let (again, _) = try BankCSVProvider(statements: [st], user: user, asOf: "2026-09-30T23:59:59-07:00").fetch()
        XCTAssertEqual(again.transactions.map(\.sourceId), ds.transactions.map(\.sourceId))
    }

    func testAmountParsing() {
        XCTAssertEqual(CSV.cents("-12.34"), -1234)
        XCTAssertEqual(CSV.cents("12.34-"), -1234)
        XCTAssertEqual(CSV.cents("(1,234.5)"), -123_450)
        XCTAssertEqual(CSV.cents("$0.07"), 7)
        XCTAssertEqual(CSV.cents("\u{2212}5"), -500)
        XCTAssertNil(CSV.cents("12.3.4"))
        XCTAssertNil(CSV.cents("abc"))
    }
}
