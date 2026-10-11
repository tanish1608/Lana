import Foundation
import XCTest
@testable import FWMCore

private let world = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("fixtures/world-v1")

final class SyntheticFixtureTests: XCTestCase {
    func testIsolatedCanonicalUsesExistingMoneyEngine() throws {
        let ds = try Dataset.load(from: world.appendingPathComponent("canonical_demo/dataset.json"))
        let view = try MoneyEngine.moneyView(ds, period: "2026-09")
        XCTAssertEqual(view.flow.netIncomeCents, 480000)
        XCTAssertEqual(view.flow.expensesCents, 315000)
        XCTAssertEqual(view.flow.toSavingsCents, 65000)
        XCTAssertEqual(view.flow.toInvestmentsCents, 40000)
        XCTAssertEqual(view.flow.retainedCashCents, 60000)
        XCTAssertEqual(view.netWorthCents, 1155000)
        XCTAssertTrue(view.reconciled)
        XCTAssertTrue(ds.contacts!.allSatisfy { $0.phone == "SYNTHETIC-NOT-A-CONTACT" && $0.venmoHandle == nil })
    }

    func testFullWorldAdapterDecodesAndReconcilesCashOnly() throws {
        // Full-world valuation and classification require supplemental records;
        // the current MoneyEngine is intentionally not called on this adapter.
        let ds = try Dataset.load(from: world.appendingPathComponent("full_financial_world/core-september.json"))
        XCTAssertEqual(ds.accounts.count, 11)
        XCTAssertGreaterThan(ds.transactions.count, 80)
        for account in ds.accounts {
            let delta = ds.transactions.filter { $0.accountId == account.accountId && !$0.pending }
                .reduce(0) { $0 + $1.signedAmountCents }
            let expected = account.openingBalanceCents! + (account.assetOrLiability == .asset ? delta : -delta)
            XCTAssertEqual(account.balanceCents, expected, account.accountId)
        }
    }

    func testDinnerSupplementUsesExistingSplitEngine() throws {
        struct Dinner: Decodable { let receipt: Receipt; let contacts: [Contact] }
        let dinner = try FWMJSON.decoder.decode(Dinner.self, from: Data(contentsOf: world.appendingPathComponent("dinner_2026_10_11/scenario.json")))
        let result = try SplitEngine.prepareSplit(receipt: dinner.receipt,
            assignments: ["it_1": ["c_tanish"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin", "c_tanish", "c_aryan"]],
            payerId: "c_ashwin", contacts: dinner.contacts)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.shares.map { ($0.contactId, $0.totalCents) }),
                       ["c_ashwin": 2860, "c_tanish": 3640, "c_aryan": 4420])
        XCTAssertEqual(result.outstandingCents, 8060)
        XCTAssertTrue(result.requests.allSatisfy { $0.venmoHandle == nil })
    }

    func testDuplicatePendingPostedUpdatesDoNotAddExpenses() throws {
        struct Edges: Decodable { let ingestionDataset: Dataset }
        let edge = try FWMJSON.decoder.decode(Edges.self, from: Data(contentsOf: world.appendingPathComponent("edge-cases.json")))
        let result = try MoneyEngine.moneyView(edge.ingestionDataset, period: "2026-09")
        XCTAssertEqual(result.flow.expensesCents, 18000)
        XCTAssertEqual(result.flow.cardRepaymentCents, 27000)
        XCTAssertEqual(result.pendingCents, 6500)
        XCTAssertTrue(result.reconciled)
    }

    func testRoundingAndReceiptFailurePaths() throws {
        XCTAssertEqual(SplitEngine.allocate(1, weights: [1, 1, 1]), [1, 0, 0])
        let ds = try Dataset.load(from: world.appendingPathComponent("canonical_demo/dataset.json"))
        var r = ds.receipts![0]
        r.totalCents += 2
        XCTAssertThrowsError(try SplitEngine.prepareSplit(receipt: r,
            assignments: ["it_1": ["c_tanish"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin"]],
            payerId: "c_ashwin", contacts: ds.contacts!)) { error in
            XCTAssertEqual((error as? ToolError)?.code, .receiptMismatch)
        }
    }
}
