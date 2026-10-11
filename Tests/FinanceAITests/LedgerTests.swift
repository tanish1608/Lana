import Foundation
import Testing
import FWMCore
@testable import FinanceAI

private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/seed-v1.json")
private func fixture() throws -> Dataset { try Dataset.load(from: fixtureURL) }
private func scope(_ ds: Dataset, accounts: Set<String>? = nil) -> CoreScope {
    .init(userID: ds.user.userId, conversationID: "c1", period: "2026-09", datasetVersion: ds.datasetVersion,
          preferencesVersion: ds.user.preferencesVersion, accountIDs: accounts ?? Set(ds.accounts.map(\.accountId)))
}
private func tempLedger() throws -> (LocalLedger, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
    return (try LocalLedger(directory: dir), dir)
}
private func withImport(_ ds: Dataset) throws -> Dataset {
    let csv = "Date,Description,Amount,Category\n2026-09-12,Blue Bottle Coffee,-6.50,Dining\n2026-09-20,Interest,1.25,Income\n"
    let (imported, _) = try BankCSVProvider(statements: [CSVStatement(accountId: "csv_ally", institution: "Ally", kind: "savings", side: .asset,
        balanceCents: 500_000, csv: csv)], user: ds.user, asOf: "2026-10-11T12:00:00-07:00").fetch()
    var out = ds
    out.accounts += imported.accounts
    out.transactions += imported.transactions
    return out
}

@Test func ledgerCategoryTotalsMatchMoneyEngine() async throws {
    let ds = try fixture(), (ledger, _) = try tempLedger()
    try await ledger.sync(ds)
    let out = try await ledger.query(.init(operation: .categories, from: "2026-09-01", to: "2026-09-30", limit: 25), scope: scope(ds))
    let view = try MoneyEngine.moneyView(ds, period: "2026-09")
    for c in view.categories { #expect(out.replyText.contains("- \(c.category): \(CoreDatasetTools.money(c.totalCents))"), "\(c.category)") }
    #expect(out.replyText.contains("Listed total \(CoreDatasetTools.money(view.flow.expensesCents))"))
    #expect(out.provenance?.datasetVersion == ds.datasetVersion)
    #expect(out.provenance?.engineVersion == LocalLedger.engineVersion)
    #expect(out.provenance?.sourceIds.isEmpty == false)
}

@Test func ledgerSearchIsScopedToUserAndOwnedAccounts() async throws {
    let ds = try fixture(), (ledger, _) = try tempLedger()
    var other = ds
    other.user.userId = "user_other"
    other.transactions = other.transactions.map { var t = $0; t.merchant = "Other Person Cafe"; return t }
    try await ledger.sync(ds)
    try await ledger.sync(other)

    let expected = ds.transactions.filter { $0.merchant.localizedCaseInsensitiveContains("trader joe") }
    let found = try await ledger.query(.init(operation: .search, text: "trader joe"), scope: scope(ds))
    #expect(found.replyText.hasPrefix("\(expected.count) matching transactions"))
    #expect(found.replyText.contains("Net \(CoreDatasetTools.money(expected.reduce(0) { $0 + $1.signedAmountCents }))"))

    let leak = try await ledger.query(.init(operation: .search, text: "Other Person"), scope: scope(ds))
    #expect(leak.replyText.hasPrefix("0 matching transactions"))

    let cardOnly = try await ledger.query(.init(operation: .search), scope: scope(ds, accounts: ["acct_card"]))
    let cardCount = ds.transactions.filter { $0.accountId == "acct_card" }.count
    #expect(cardOnly.replyText.hasPrefix("\(cardCount) matching transactions"))
}

@Test func ledgerTreatsModelTextAsDataAndValidatesDates() async throws {
    let ds = try fixture(), (ledger, _) = try tempLedger()
    try await ledger.sync(ds)
    let injected = try await ledger.query(.init(operation: .search, text: "%' OR 1=1 --"), scope: scope(ds))
    #expect(injected.replyText.hasPrefix("0 matching transactions"))
    let wildcard = try await ledger.query(.init(operation: .merchants, text: "_"), scope: scope(ds))
    #expect(wildcard.replyText.contains("Listed total $0.00"))
    await #expect(throws: ToolError.self) { try await ledger.query(.init(operation: .search, from: "2026-02-30"), scope: scope(ds)) }
    await #expect(throws: ToolError.self) { try await ledger.query(.init(operation: .search, from: "2026-09-30", to: "2026-09-01"), scope: scope(ds)) }
    await #expect(throws: ToolError.self) { try await ledger.query(.init(operation: .search), scope: scope(ds, accounts: [])) }
}

@Test func ledgerRestoresImportedAccountsAfterReopen() async throws {
    let ds = try withImport(try fixture()), (ledger, dir) = try tempLedger()
    try await ledger.sync(ds)
    let reopened = try LocalLedger(directory: dir)
    let restored = try await reopened.importedAccounts(userID: ds.user.userId)
    #expect(restored.count == 1)
    #expect(restored.first?.account == ds.accounts.first { $0.accountId == "csv_ally" })
    #expect(restored.first?.transactions == ds.transactions.filter { $0.accountId == "csv_ally" }.sorted { ($0.postedAt, $0.transactionId) < ($1.postedAt, $1.transactionId) })
    // Fixture accounts are mirrored for search but never restored as imports.
    #expect(try await reopened.importedAccounts(userID: "user_other").isEmpty)
    let search = try await reopened.query(.init(operation: .search, text: "Blue Bottle Coffee"), scope: scope(ds))
    #expect(search.replyText.contains("imported"))
    #expect(search.provenance?.dataMode == .cached)
}

@Test func ledgerJournalKeepsActivityPerUser() async throws {
    let ds = try fixture(), (ledger, _) = try tempLedger()
    try await ledger.record(.init(kind: "plan_adopted", summary: "Adopted budget plan saving $150/month", details: ["savings_cents": "15000"]), userID: ds.user.userId)
    try await ledger.record(.init(kind: "account_imported", summary: "Imported Ally Savings ••1234"), userID: ds.user.userId)
    try await ledger.record(.init(kind: "account_imported", summary: "Someone else's import"), userID: "user_other")
    let mine = try await ledger.events(userID: ds.user.userId)
    #expect(mine.map(\.kind) == ["account_imported", "plan_adopted"])
    #expect(mine.last?.details["savings_cents"] == "15000")
    let adopted = try await ledger.query(.init(operation: .activity, text: "adopt"), scope: scope(ds))
    #expect(adopted.replyText.contains("Adopted budget plan saving $150/month"))
    #expect(!adopted.replyText.contains("Ally"))
    #expect(!adopted.replyText.contains("Someone else"))
}

@Test func ledgerReadsDatesTheUserWrote() {
    #expect(LedgerRequest.dateWindow(in: "between 2026-09-01 and 2026-09-30?", period: "2026-09")! == ("2026-09-01", "2026-09-30"))
    #expect(LedgerRequest.dateWindow(in: "from 2026-09-30 back to 2026-09-10", period: "2026-09")! == ("2026-09-10", "2026-09-30"))
    #expect(LedgerRequest.dateWindow(in: "Trader Joe's in 2026-08", period: "2026-09")! == ("2026-08-01", "2026-08-31"))
    #expect(LedgerRequest.dateWindow(in: "What did I spend in September?", period: "2026-09")! == ("2026-09-01", "2026-09-30"))
    #expect(LedgerRequest.dateWindow(in: "dining in February 2024", period: "2026-09")! == ("2024-02-01", "2024-02-29"))
    #expect(LedgerRequest.dateWindow(in: "May I see my Costco runs?", period: "2026-09") == nil)
    #expect(LedgerRequest.dateWindow(in: "How much at Costco?", period: "2026-09") == nil)
    #expect(LedgerRequest.dateWindow(in: "July or August?", period: "2026-09") == nil) // ambiguous: leave it to the model
}

@Test func ledgerSaysWhenAnAnswerHasNoDateFilter() async throws {
    let ds = try fixture(), (ledger, _) = try tempLedger()
    try await ledger.sync(ds)
    let all = try await ledger.query(.init(operation: .search, text: "Trader Joe's"), scope: scope(ds))
    #expect(all.replyText.contains("with no date filter (all stored transactions, 2026-07-03 to 2026-09-17)"))
    let sep = try await ledger.query(.init(operation: .search, text: "Trader Joe's", from: "2026-09-01", to: "2026-09-30"), scope: scope(ds))
    #expect(sep.replyText.contains("from 2026-09-01 to 2026-09-30"))
    #expect(sep.replyText.contains("spending (excluding transfers, pending and income) $261.50"))
}
