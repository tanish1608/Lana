import XCTest
@testable import FWMCore

final class SimpleFINTests: XCTestCase {
    private let user = UserPrefs(userId: "user_ashwin", displayName: "Ashwin", timezone: "America/Los_Angeles", currency: "USD",
                                 brandLocks: [], dietaryRules: [], savingsGoalCents: 15_000, preferencesVersion: 1)
    // Same shape as SimpleFIN's demo response, trimmed.
    private let payload = #"""
    {"errlist":[],"connections":[{"conn_id":"CON-1","name":"Chase","org_id":"chase","org_name":"Chase Bank"}],
     "accounts":[
      {"id":"chk","name":"Total Checking","conn_id":"CON-1","currency":"USD","balance":"2410.07","balance-date":1791763200,
       "transactions":[{"id":"t1","posted":1791705600,"amount":"-55.50","description":"Fishing bait","payee":"John's Fishin Shack","mcc":"5812"},
                       {"id":"t2","posted":0,"transacted_at":1791734400,"amount":"-85.5","description":"LOCAL GROCER #1133","mcc":"5411","pending":true},
                       {"id":"t3","posted":1791792000,"amount":"12.345","description":"Bad precision"}]},
      {"id":"cc","name":"Freedom Credit Card","conn_id":"CON-1","currency":"USD","balance":"-900.00","balance-date":1791763200,"transactions":[]},
      {"id":"eur","name":"Euro Savings","conn_id":"CON-1","currency":"EUR","balance":"10.00","balance-date":1791763200}
     ]}
    """#

    func testNormalizesAccountsTransactionsAndSigns() throws {
        let set = try JSONDecoder().decode(SimpleFIN.AccountSet.self, from: Data(payload.utf8))
        let out = SimpleFIN.normalize(set, user: user, asOf: "2026-10-11T12:00:00-07:00")
        XCTAssertEqual(out.accounts.map(\.kind), ["checking", "credit_card"])
        XCTAssertEqual(out.accounts.map(\.institution), ["Chase", "Chase"])
        XCTAssertEqual(out.accounts.map(\.balanceCents), [241_007, 90_000], "card debt becomes a positive amount owed")
        XCTAssertEqual(out.accounts[1].assetOrLiability, .liability)
        XCTAssertTrue(out.accounts.allSatisfy { $0.sourceId?.hasPrefix("sfin:") == true && $0.openingBalanceCents == nil })
        XCTAssertEqual(out.transactions.map(\.signedAmountCents), [-5_550, -8_550])
        XCTAssertEqual(out.transactions.map(\.merchant), ["John's Fishin Shack", "LOCAL GROCER #1133"])
        XCTAssertEqual(out.transactions.map(\.category), ["Dining", "Groceries"])
        XCTAssertEqual(out.transactions.map(\.pending), [false, true])
        XCTAssertTrue(out.transactions[0].postedAt.hasSuffix("-07:00"), out.transactions[0].postedAt)
        XCTAssertTrue(out.warnings.contains { $0.contains("EUR") })
        XCTAssertTrue(out.warnings.contains { $0.contains("Bad precision") })
        // IDs are stable across fetches, so a refresh replaces rather than duplicates.
        XCTAssertEqual(SimpleFIN.normalize(set, user: user, asOf: "x").transactions.map(\.transactionId), out.transactions.map(\.transactionId))
    }

    func testSetupTokenMustDecodeToHTTPS() throws {
        let demo = "aHR0cHM6Ly9icmlkZ2Uuc2ltcGxlZmluLm9yZy9zaW1wbGVmaW4vY2xhaW0vZGVtbw=="
        XCTAssertEqual(try SimpleFIN.claimURL(setupToken: demo).absoluteString, "https://bridge.simplefin.org/simplefin/claim/demo")
        XCTAssertThrowsError(try SimpleFIN.claimURL(setupToken: Data("http://example.com/claim".utf8).base64EncodedString()))
        XCTAssertThrowsError(try SimpleFIN.claimURL(setupToken: "not a token"))
        XCTAssertEqual(SimpleFIN.cents("-0.07"), -7)
        XCTAssertNil(SimpleFIN.cents("1.234"))
    }

    /// Reads SimpleFIN's public demo server. Opt in: FWM_LIVE_SIMPLEFIN=1.
    func testLiveDemoServer() async throws {
        guard ProcessInfo.processInfo.environment["FWM_LIVE_SIMPLEFIN"] == "1" else { throw XCTSkip("Opt in with FWM_LIVE_SIMPLEFIN=1") }
        let set = try await SimpleFIN.fetch(accessURL: SimpleFIN.demoAccessURL, since: Date().addingTimeInterval(-60 * 86_400))
        let out = SimpleFIN.normalize(set, user: user, asOf: "now")
        XCTAssertFalse(out.accounts.isEmpty)
        XCTAssertFalse(out.transactions.isEmpty)
    }
}
