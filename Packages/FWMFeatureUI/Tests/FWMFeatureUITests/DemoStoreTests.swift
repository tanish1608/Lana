import XCTest
import FWMCore
@testable import FWMFeatureUI

// The screens read engine results; these check the fixture wiring and the budget stand-in's arithmetic.
final class DemoStoreTests: XCTestCase {
    func testLoadsSeedAndSplitExample() throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        XCTAssertEqual(s.periods, ["2026-07", "2026-08", "2026-09", "2026-10"])
        XCTAssertEqual(s.splitExample?.payerId, "c_ashwin")
    }

    func testBudgetStandInMeetsGoalWithoutTouchingRentOrTransfers() throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let v = try MoneyEngine.moneyView(s.dataset, period: PreviewBudgetPlan.basePeriod)
        let swaps = PreviewBudgetPlan.swaps.reduce(0) { $0 + $1.savingsCents }
        let habits = PreviewBudgetPlan.habits.reduce(0) { $0 + $1.savingsCents }
        XCTAssertEqual(swaps, 10_000)
        XCTAssertEqual(swaps + habits, PreviewBudgetPlan.goalCents)
        XCTAssertFalse(PreviewBudgetPlan.swaps.contains { $0.category == "Rent" } || PreviewBudgetPlan.habits.contains { $0.category == "Rent" })
        let categories = Set(v.categories.map(\.category))
        XCTAssertTrue(PreviewBudgetPlan.swaps.allSatisfy { categories.contains($0.category) })
        XCTAssertTrue(PreviewBudgetPlan.habits.allSatisfy { categories.contains($0.category) })
        XCTAssertEqual(v.flow.retainedCashCents + swaps + habits, 75_000)
    }

    func testHomePercentsTotalOneHundred() throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let f = try MoneyEngine.moneyView(s.dataset, period: s.snapshotPeriod).flow
        let p = HomeScreen.percents([f.expensesCents, f.toSavingsCents, f.toInvestmentsCents, f.retainedCashCents])
        XCTAssertEqual(p, [66, 14, 8, 12])
        XCTAssertEqual(HomeScreen.percents([1, 1, 1]).reduce(0, +), 100)
    }

    func testEverySwapHasAnActionLanaCanOfferAndHabitsHaveNone() {
        XCTAssertTrue((PreviewBudgetPlan.swaps + [PreviewBudgetPlan.instantCoffee]).allSatisfy { BudgetIdea.actions[$0.id] != nil })
        XCTAssertTrue(PreviewBudgetPlan.habits.allSatisfy { !BudgetIdea($0).isSwap })
    }

    func testMessagesLineComesFromConfigAndRejectsJunk() {
        XCTAssertNil(LanaMessagesLine.url(infoValue: nil))
        XCTAssertNil(LanaMessagesLine.url(infoValue: "not a number"))
        XCTAssertEqual(LanaMessagesLine.url(infoValue: "+1 (555) 010-0199")?.absoluteString, "sms:+15550100199")
    }
}

final class ThreeYearDataTests: XCTestCase {
    func testThreeYearWorldLoadsReconcilesAndKeepsTheBudgetWorking() throws {
        let s = try DemoStore(fixtureURL: try XCTUnwrap(DemoStore.threeYearURL))
        XCTAssertGreaterThan(s.dataset.transactions.count, 2_800, "three years of bank and card history")
        XCTAssertEqual(s.dataset.accounts.count, 14, "11 accounts plus securities, prediction positions and the condo")
        XCTAssertEqual(s.snapshotPeriod, "2026-09")
        XCTAssertEqual(s.periods.first, "2023-10")
        let v = try MoneyEngine.moneyView(s.dataset, period: "2026-09")
        XCTAssertTrue(v.reconciled, "September statements reconcile with September activity")
        XCTAssertTrue(v.accounts.allSatisfy { $0.reconciled == true })
        // The world's own September summary.
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: DemoStore.repoSeedURL().deletingLastPathComponent()
            .appendingPathComponent("world-v1/full_financial_world/september.json"))) as! [String: Any]
        let expected = summary["summary"] as! [String: Any]
        XCTAssertEqual(v.assetsCents, expected["assets_cents"] as? Int)
        XCTAssertEqual(v.liabilitiesCents, expected["liabilities_cents"] as? Int)
        XCTAssertEqual(v.netWorthCents, expected["net_worth_cents"] as? Int)
        XCTAssertFalse(v.categories.contains { $0.category == "Uncategorized" }, "investment trading isn't spending")
        let p = try BudgetProjection.make(dataset: s.dataset, period: "2026-09", accepted: Set(PreviewBudgetPlan.swaps.map(\.id) + PreviewBudgetPlan.habits.map(\.id)), useHistory: true)
        XCTAssertEqual(p.savingsCents, PreviewBudgetPlan.goalCents)
        XCTAssertNotNil(s.fixtureSplit(), "the dinner split still works")
    }
}
