import XCTest
import FWMCore
@testable import FWMFeatureUI

// Accounts screen: real institution names and logos for the seed, and statement import through BankCSVProvider.
final class AccountsTests: XCTestCase {
    func testSeedInstitutionsAreRecognisedWithBundledLogos() throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let names = Set(s.dataset.accounts.map(\.institution))
        XCTAssertEqual(names, ["Chase", "Robinhood", "Capital One", "Sallie Mae"])
        for name in names { XCTAssertNotNil(Institution.named(name), name) }
        for i in Institution.all {
            XCTAssertNotNil(Bundle.module.url(forResource: i.id, withExtension: "png"), "missing logo \(i.id)")
            XCTAssertFalse(i.kinds.isEmpty, i.id)
        }
        XCTAssertEqual(Institution.named("amex")?.id, "american_express")
        XCTAssertEqual(Set(Institution.all.map(\.id)).count, Institution.all.count)
    }

    func testAccountDisplayIsStable() throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let checking = try XCTUnwrap(s.dataset.accounts.first { $0.kind == "checking" })
        let d = AccountDisplay(checking)
        XCTAssertEqual(d.title, "Chase Total Checking")
        XCTAssertEqual(d.mask, AccountDisplay(checking).mask)
        XCTAssertEqual(d.mask.count, 4)
        XCTAssertFalse(d.isImported)
    }

    func testBalanceParsing() {
        XCTAssertEqual(StatementImport.cents("1,250.5"), 125_050)
        XCTAssertEqual(StatementImport.cents("$80"), 8_000)
        XCTAssertEqual(StatementImport.cents(".07"), 7)
        XCTAssertNil(StatementImport.cents("-5"))
        XCTAssertNil(StatementImport.cents("1.234"))
        XCTAssertNil(StatementImport.cents("abc"))
        XCTAssertNil(StatementImport.cents(""))
    }

    func testCardStatementImportFlipsPositivePurchases() throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let csv = "Transaction Date,Description,Amount,Category\n09/03/2026,Blue Bottle,6.50,Dining\n09/05/2026,Whole Foods,42.10,Groceries\n09/20/2026,Payment Thank You,-48.60,Payment\n"
        var job = StatementImport(institution: try XCTUnwrap(Institution.id("citi")), kind: "credit_card", balanceCents: 4_860, csv: csv, user: s.dataset.user)
        let raw = try job.run(accountID: "csv_test", asOf: "2026-10-11T12:00:00-07:00")
        XCTAssertTrue(StatementImport.chargesLookPositive(raw.transactions))
        job.flipSigns = true
        let out = try job.run(accountID: "csv_test", asOf: "2026-10-11T12:00:00-07:00")
        XCTAssertEqual(out.account.assetOrLiability, .liability)
        XCTAssertEqual(out.account.institution, "Citi")
        XCTAssertEqual(out.transactions.map(\.signedAmountCents).sorted(), [-4_210, -650, 4_860])
        XCTAssertTrue(AccountDisplay(out.account).isImported)
    }

    @MainActor
    func testImportedAccountJoinsSessionAndInvalidatesEvidence() throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let chat = LanaChatController(dataset: s.dataset, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let before = try MoneyEngine.moneyView(chat.dataset, period: "2026-09")
        let csv = "Date,Description,Amount\n2026-09-10,Interest,12.00\n"
        let out = try StatementImport(institution: try XCTUnwrap(Institution.id("ally")), kind: "savings", balanceCents: 500_000, csv: csv, user: s.dataset.user)
            .run(accountID: "csv_ally", asOf: "2026-10-11T12:00:00-07:00")
        let version = chat.dataset.datasetVersion
        chat.addAccount(out.account, transactions: out.transactions)
        XCTAssertNotEqual(chat.dataset.datasetVersion, version)
        let after = try MoneyEngine.moneyView(chat.dataset, period: "2026-09")
        XCTAssertEqual(after.netWorthCents - before.netWorthCents, 500_000)
        chat.removeImportedAccount("acct_checking") // fixture accounts can't be removed
        XCTAssertTrue(chat.dataset.accounts.contains { $0.accountId == "acct_checking" })
        chat.removeImportedAccount("csv_ally")
        XCTAssertEqual(try MoneyEngine.moneyView(chat.dataset, period: "2026-09").netWorthCents, before.netWorthCents)
        XCTAssertFalse(chat.dataset.transactions.contains { $0.accountId == "csv_ally" })
    }
}
