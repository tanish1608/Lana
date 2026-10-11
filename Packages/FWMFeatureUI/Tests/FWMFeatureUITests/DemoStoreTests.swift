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
}
