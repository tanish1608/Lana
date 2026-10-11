import XCTest
@testable import FWMCore

// Golden numbers from SRS v2 pages 4-6 (T02, T05). If a fixture or engine change breaks these, the demo numbers are wrong.

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")

final class MoneyEngineTests: XCTestCase {
    func testCanonicalSeptember() throws {
        let ds = try Dataset.load(from: fixtures.appendingPathComponent("seed-v1.json"))
        let v = try MoneyEngine.moneyView(ds, period: "2026-09")
        XCTAssertEqual(v.flow.netIncomeCents, 480_000)
        XCTAssertEqual(v.flow.expensesCents, 315_000)
        XCTAssertEqual(v.flow.toSavingsCents, 65_000)
        XCTAssertEqual(v.flow.toInvestmentsCents, 40_000)
        XCTAssertEqual(v.flow.retainedCashCents, 60_000)
        XCTAssertEqual(v.flow.netIncomeCents, v.flow.expensesCents + v.flow.toSavingsCents + v.flow.toInvestmentsCents + v.flow.retainedCashCents)
        XCTAssertEqual(v.categories.reduce(0) { $0 + $1.totalCents }, 315_000)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: v.categories.map { ($0.category, $0.totalCents) }),
                       ["Rent": 160_000, "Groceries": 50_000, "Dining": 30_000, "Transport": 25_000, "Bills and subscriptions": 25_000, "Other": 25_000])
        XCTAssertEqual(v.assetsCents, 2_445_000)
        XCTAssertEqual(v.liabilitiesCents, 1_290_000)
        XCTAssertEqual(v.netWorthCents, 1_155_000)
        XCTAssertTrue(v.reconciled)
        XCTAssertEqual(v.provenance.resultId, "mv:seed-v1:2026-09:all")
    }

    func testEdgeCasesDoNotInflateSpending() throws {
        let ds = try Dataset.load(from: fixtures.appendingPathComponent("edge-v1.json"))
        let v = try MoneyEngine.moneyView(ds, period: "2026-09")
        XCTAssertEqual(v.flow.netIncomeCents, 50_000)
        XCTAssertEqual(v.flow.expensesCents, 18_000) // card purchase − refund + groceries; repayment excluded
        XCTAssertEqual(v.flow.toSavingsCents, 10_000)
        XCTAssertEqual(v.flow.cardRepaymentCents, 27_000)
        XCTAssertEqual(v.pendingCents, 6_500)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: v.categories.map { ($0.category, $0.totalCents) }), ["Other": 9_000, "Groceries": 9_000])
        XCTAssertTrue(v.excluded.contains { $0.transactionId == "e4" && $0.reason == .cardRepayment })
        XCTAssertTrue(v.excluded.contains { $0.transactionId == "e8" && $0.reason == .pending })
        XCTAssertTrue(v.reconciled)
    }

    func testRejectsBadPeriod() throws {
        let ds = try Dataset.load(from: fixtures.appendingPathComponent("seed-v1.json"))
        XCTAssertThrowsError(try MoneyEngine.moneyView(ds, period: "last month"))
    }
}

final class SplitEngineTests: XCTestCase {
    func testDinnerReceipt() throws {
        let ds = try Dataset.load(from: fixtures.appendingPathComponent("seed-v1.json"))
        let r = try SplitEngine.prepareSplit(
            receipt: ds.receipts![0],
            assignments: ["it_1": ["c_tanish"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin", "c_tanish", "c_aryan"]],
            payerId: "c_ashwin", contacts: ds.contacts!)
        let totals = Dictionary(uniqueKeysWithValues: r.shares.map { ($0.contactId, $0.totalCents) })
        XCTAssertEqual(totals, ["c_ashwin": 2_860, "c_tanish": 3_640, "c_aryan": 4_420])
        XCTAssertEqual(r.shares.reduce(0) { $0 + $1.totalCents }, 10_920)
        XCTAssertEqual(r.outstandingCents, 8_060)
        XCTAssertEqual(Set(r.requests.map(\.contactId)), ["c_tanish", "c_aryan"])
    }

    func testMismatchedReceiptIsBlocked() throws {
        let ds = try Dataset.load(from: fixtures.appendingPathComponent("seed-v1.json"))
        var bad = ds.receipts![0]
        bad.totalCents += 100
        XCTAssertThrowsError(try SplitEngine.prepareSplit(receipt: bad, assignments: ["it_1": ["c_tanish"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin"]],
                                                          payerId: "c_ashwin", contacts: ds.contacts!)) { e in
            XCTAssertEqual((e as? ToolError)?.code, .receiptMismatch)
        }
    }

    func testUnknownContactIsBlocked() throws {
        let ds = try Dataset.load(from: fixtures.appendingPathComponent("seed-v1.json"))
        XCTAssertThrowsError(try SplitEngine.prepareSplit(receipt: ds.receipts![0], assignments: ["it_1": ["c_bob"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin"]],
                                                          payerId: "c_ashwin", contacts: ds.contacts!)) { e in
            XCTAssertEqual((e as? ToolError)?.code, .ambiguousContact)
        }
    }

    func testLargestRemainderSumsExactly() {
        XCTAssertEqual(SplitEngine.allocate(1_000, weights: [1, 1, 1]), [334, 333, 333])
        XCTAssertEqual(SplitEngine.allocate(2_520, weights: [2_200, 2_800, 3_400]), [660, 840, 1_020])
        XCTAssertEqual(SplitEngine.allocate(7, weights: [1, 1, 1, 1]).reduce(0, +), 7)
    }
}

final class ContractTests: XCTestCase {
    func testToolCallAllowlist() {
        let ok = #"{"tool":"get_money_view","arguments":{"period":"2026-09"}}"#.data(using: .utf8)!
        XCTAssertEqual(try ToolCall.parse(ok).get(), .getMoneyView(period: "2026-09", accountFilter: nil))
        let unknown = #"{"tool":"transfer_money","arguments":{}}"#.data(using: .utf8)!
        if case .failure(let e) = ToolCall.parse(unknown) { XCTAssertEqual(e.code, .unknownTool) } else { XCTFail() }
        let malformed = #"{"tool":"prepare_split","arguments":{"receipt_id":"r"}}"#.data(using: .utf8)!
        if case .failure(let e) = ToolCall.parse(malformed) { XCTAssertEqual(e.code, .invalidArguments) } else { XCTFail() }
    }
}
