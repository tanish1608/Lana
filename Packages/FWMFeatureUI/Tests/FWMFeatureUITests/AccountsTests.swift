import XCTest
import FWMCore
import FinanceAI
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

    @MainActor
    func testImportedAccountAndApprovalsSurviveRelaunch() async throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = LanaChatController(dataset: s.dataset, directory: dir)
        XCTAssertNotNil(first.ledger)
        let out = try StatementImport(institution: try XCTUnwrap(Institution.id("chase")), kind: "credit_card", balanceCents: 1_250,
                                      csv: "Date,Description,Amount\n2026-09-15,Blue Bottle,-12.50\n", user: s.dataset.user)
            .run(accountID: "csv_relaunch", asOf: "2026-10-11T12:00:00-07:00")
        first.addAccount(out.account, transactions: out.transactions)
        first.journal("account_imported", "Imported Chase card")
        first.journal("budget_selection", "Budget plan has 3 kept ideas")
        await first.ledgerSettled()

        // A new controller on the same storage is what the app sees after relaunch.
        let second = LanaChatController(dataset: s.dataset, directory: dir)
        XCTAssertFalse(second.dataset.accounts.contains { $0.accountId == "csv_relaunch" })
        await second.restore()
        XCTAssertTrue(second.dataset.accounts.contains { $0.accountId == "csv_relaunch" })
        XCTAssertEqual(second.dataset.transactions.filter { $0.accountId == "csv_relaunch" }.map(\.signedAmountCents), [-1_250])
        let approvals = await second.approvalLog()
        XCTAssertEqual(approvals, ["Imported Chase card"]) // budget selections are activity, not approvals

        // The agent's ledger sees the restored account through the conversation's scope.
        await second.ledgerSettled()
        let ledger = try XCTUnwrap(second.ledger)
        let found = try await ledger.query(.init(operation: .search, text: "Blue Bottle"), scope: second.scope)
        XCTAssertTrue(found.replyText.contains("imported"), found.replyText)
        let activity = try await ledger.query(.init(operation: .activity), scope: second.scope)
        XCTAssertTrue(activity.replyText.contains("Budget plan has 3 kept ideas"))
    }
}

/// Keychain stand-in for tests; the app uses KeychainVault (device-only, user presence).
actor MemoryVault: SecretStoring {
    var items: [String: Data] = [:]
    func store(_ secret: Data, for key: VaultKey) async throws { items[key.userID + "/" + key.name] = secret }
    func read(_ key: VaultKey, reason: String) async throws -> Data {
        guard let d = items[key.userID + "/" + key.name] else { throw VaultFailure("No credential is stored for this service.") }
        return d
    }
    func remove(_ key: VaultKey) async throws { items[key.userID + "/" + key.name] = nil }
}

final class ConnectionTests: XCTestCase {
    @MainActor
    func testSimpleFINConnectionIsSavedRefreshedAndRemoved() async throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = LanaChatController(dataset: s.dataset, directory: dir)
        let vault = MemoryVault(); chat.vault = vault
        // Accounts as the connect screen hands them over.
        let payload = #"{"connections":[{"conn_id":"C","name":"Chase"}],"accounts":[{"id":"a","name":"Checking","conn_id":"C","currency":"USD","balance":"10.00","balance-date":1791763200,"transactions":[{"id":"t","posted":1791705600,"amount":"-1.00","description":"Coffee"}]}]}"#
        let n = SimpleFIN.normalize(try JSONDecoder().decode(SimpleFIN.AccountSet.self, from: Data(payload.utf8)), user: s.dataset.user, asOf: "x")
        for a in n.accounts { chat.addAccount(a, transactions: n.transactions) }
        let note = await chat.saveSimpleFIN(accessURL: SimpleFIN.demoAccessURL, label: "Chase via SimpleFIN", accountIDs: n.accounts.map(\.accountId))
        XCTAssertNil(note)
        XCTAssertEqual(chat.connections.map(\.label), ["Chase via SimpleFIN"])
        let stored = await vault.items
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.values.first.map { String(decoding: $0, as: UTF8.self) }, SimpleFIN.demoAccessURL.absoluteString)

        // After relaunch the connection is listed again (credential still in the Keychain).
        let relaunched = LanaChatController(dataset: s.dataset, directory: dir); relaunched.vault = vault
        await relaunched.restore()
        XCTAssertEqual(relaunched.connections.map(\.accountIDs), [n.accounts.map(\.accountId)])
        XCTAssertTrue(relaunched.dataset.accounts.contains { $0.accountId == n.accounts[0].accountId })

        await relaunched.removeConnection(relaunched.connections[0])
        XCTAssertTrue(relaunched.connections.isEmpty)
        XCTAssertFalse(relaunched.dataset.accounts.contains { $0.accountId == n.accounts[0].accountId })
        let left = await vault.items
        XCTAssertTrue(left.isEmpty)
    }

    /// Refresh against SimpleFIN's public demo server. Opt in: FWM_LIVE_SIMPLEFIN=1.
    @MainActor
    func testLiveRefreshFromSimpleFINDemo() async throws {
        guard ProcessInfo.processInfo.environment["FWM_LIVE_SIMPLEFIN"] == "1" else { throw XCTSkip("Opt in with FWM_LIVE_SIMPLEFIN=1") }
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let chat = LanaChatController(dataset: s.dataset, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        chat.vault = MemoryVault()
        let set = try await SimpleFIN.fetch(accessURL: SimpleFIN.demoAccessURL, since: Date().addingTimeInterval(-90 * 86_400))
        let n = SimpleFIN.normalize(set, user: s.dataset.user, asOf: "x")
        let first = try XCTUnwrap(n.accounts.first)
        chat.addAccount(first, transactions: [])
        _ = await chat.saveSimpleFIN(accessURL: SimpleFIN.demoAccessURL, label: "SimpleFIN Demo via SimpleFIN", accountIDs: [first.accountId])
        let message = try await chat.refresh(chat.connections[0])
        XCTAssertTrue(message.hasPrefix("Refreshed"), message)
        XCTAssertEqual(chat.dataset.transactions.filter { $0.accountId == first.accountId }.count, n.transactions.filter { $0.accountId == first.accountId }.count)
    }
}
