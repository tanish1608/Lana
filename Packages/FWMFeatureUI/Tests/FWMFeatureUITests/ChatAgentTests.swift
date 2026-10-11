import XCTest
import FinanceAI
import FWMCore
@testable import FWMFeatureUI

// Chat as an agent: the model's words resolve to exact IDs on a confirm card; only a confirmed card changes anything.
final class ChatAgentTests: XCTestCase {
    private func planner(_ ds: Dataset, requests: [ChatRequestRow] = []) -> ChatActionPlanner { ChatActionPlanner(dataset: ds, requests: requests, useHistory: true) }
    private func scope(_ ds: Dataset) -> CoreScope {
        CoreScope(userID: ds.user.userId, conversationID: "c", period: "2026-09", datasetVersion: ds.datasetVersion,
                  preferencesVersion: ds.user.preferencesVersion, accountIDs: Set(ds.accounts.map(\.accountId)))
    }

    func testPlannerResolvesWordsToExactIDsOrAsks() async throws {
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let keep = try await planner(ds).plan(.init(kind: .keepIdea, target: "the phone plan"), scope: scope(ds))
        XCTAssertEqual(keep.kind, "keep_idea")
        XCTAssertEqual(keep.payload, ["idea_id": "s_phone", "keep": "true"])
        XCTAssertEqual(keep.status, .proposed)

        do { _ = try await planner(ds).plan(.init(kind: .skipIdea, target: "groceries"), scope: scope(ds)); XCTFail("two grocery ideas should ask") }
        catch let e as ToolError { XCTAssertTrue(e.userMessage.contains("Pantry staples") && e.userMessage.contains("Laundry detergent"), e.userMessage) }

        let rows = [ChatRequestRow(contactID: "c_tanish", name: "Tanish", amountCents: 3_640, state: "Draft")]
        let paid = try await planner(ds, requests: rows).plan(.init(kind: .markPaid, target: "Tanish"), scope: scope(ds))
        XCTAssertEqual(paid.payload, ["contact_id": "c_tanish", "state": "paid_reported"])
        XCTAssertTrue(paid.title.contains("$36.40"))

        let move = try await planner(ds).plan(.init(kind: .recategorize, target: "Target", value: "groceries"), scope: scope(ds))
        let targets = ds.transactions.filter { $0.merchant == "Target" }.map(\.transactionId)
        XCTAssertEqual(Set(move.payload["transaction_ids"]!.split(separator: ",").map(String.init)), Set(targets))
        XCTAssertEqual(move.payload["category"], "Groceries")

        do { _ = try await planner(ds).plan(.init(kind: .recategorize, target: "Target", value: "Vacation"), scope: scope(ds)); XCTFail() }
        catch let e as ToolError { XCTAssertTrue(e.userMessage.contains("Choose one of"), e.userMessage) }
        do { _ = try await planner(ds).plan(.init(kind: .removeAccount, target: "Chase checking"), scope: scope(ds)); XCTFail("fixture accounts aren't removable") }
        catch let e as ToolError { XCTAssertTrue(e.userMessage.contains("imported or linked"), e.userMessage) }
        let open = try await planner(ds).plan(.init(kind: .openScreen, target: "budget"), scope: scope(ds))
        XCTAssertEqual(open.payload, ["screen": "budget"])
    }

    @MainActor
    func testConfirmedRecategorizationRunsOnceAndSurvivesRelaunch() async throws {
        let s = try XCTUnwrap(DemoStore.repoSeed())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = LanaChatController(dataset: s.dataset, directory: dir)
        let before = try MoneyEngine.moneyView(chat.dataset, period: "2026-09").categories
        let action = try await planner(chat.dataset).plan(.init(kind: .recategorize, target: "Target", value: "Groceries"), scope: chat.scope)
        chat.archive?.messages.append(.init(role: .assistant, text: "Ready to confirm.", actions: [action]))
        let message = try XCTUnwrap(chat.archive?.messages.last?.id)
        var runs = 0
        let perform: @MainActor (ChatAction) async throws -> String = { a in
            runs += 1
            let ids = Set(a.payload["transaction_ids"]!.split(separator: ",").map(String.init))
            return "Moved \(chat.recategorize(ids, to: a.payload["category"]!))"
        }
        await chat.confirm(action, in: message, perform: perform)
        await chat.confirm(action, in: message, perform: perform) // a second tap does nothing
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(chat.archive?.messages.last?.actions?.first?.status, .done)
        let after = try MoneyEngine.moneyView(chat.dataset, period: "2026-09").categories
        let target = s.dataset.transactions.filter { $0.merchant == "Target" && $0.postedAt.hasPrefix("2026-09") }.reduce(0) { $0 - $1.signedAmountCents }
        XCTAssertEqual(after.first { $0.category == "Groceries" }!.totalCents, before.first { $0.category == "Groceries" }!.totalCents + target)
        let approvals = await chat.approvalLog()
        XCTAssertTrue(approvals.first?.contains("confirmed in chat") == true, "\(approvals)")

        let relaunched = LanaChatController(dataset: s.dataset, directory: dir)
        await relaunched.restore()
        XCTAssertTrue(relaunched.dataset.transactions.filter { $0.merchant == "Target" }.allSatisfy { $0.category == "Groceries" })

        // Cancelling leaves everything as it was.
        let skip = try await planner(chat.dataset).plan(.init(kind: .skipIdea, target: "coffee"), scope: chat.scope)
        chat.archive?.messages.append(.init(role: .assistant, text: "Skip it?", actions: [skip]))
        let second = try XCTUnwrap(chat.archive?.messages.last?.id)
        await chat.cancel(skip, in: second)
        await chat.confirm(skip, in: second, perform: perform)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(chat.archive?.messages.last?.actions?.first?.status, .cancelled)
    }

    func testChartsCarryTheEnginesOwnFigures() async throws {
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let money = try await FeatureTools(dataset: ds).query(.getMoneyView(period: "2026-09", accountFilter: nil), scope: scope(ds))
        let view = try MoneyEngine.moneyView(ds, period: "2026-09")
        XCTAssertEqual(money.chart?.style, .bars)
        XCTAssertEqual(money.chart?.points.map(\.cents), view.categories.map(\.totalCents))
        let budget = try await FeatureTools(dataset: ds).query(.proposeBudget(period: "2026-09", extraSavingsCents: 15_000), scope: scope(ds))
        XCTAssertEqual(budget.chart?.style, .comparison)
        XCTAssertEqual(budget.chart?.points.reduce(0) { $0 + $1.cents - ($1.secondCents ?? $1.cents) }, 15_000, "now minus plan is the projected saving")

        let ledger = try LocalLedger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await ledger.sync(ds)
        let tj = try await ledger.query(.init(operation: .search, text: "Trader Joe's"), scope: scope(ds))
        XCTAssertEqual(tj.chart?.style, .columns)
        XCTAssertEqual(tj.chart?.points.map(\.label), ["Jul 2026", "Aug 2026", "Sep 2026"])
        XCTAssertEqual(tj.chart?.points.map(\.cents), [26_150, 26_150, 26_150])
    }

    func testActualModelProposesActionsAndCharts() async throws {
        guard ProcessInfo.processInfo.environment["FWM_TEST_MODEL"] == "1" else { throw XCTSkip("Opt in with FWM_TEST_MODEL=1 on a model-ready Mac.") }
        XCTAssertEqual(OnDeviceRouter.status, .ready)
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let ledger = try LocalLedger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await ledger.sync(ds)
        let sc = CoreScope(userID: ds.user.userId, conversationID: "c", period: "2026-09", datasetVersion: ds.datasetVersion,
                           preferencesVersion: ds.user.preferencesVersion, accountIDs: Set(ds.accounts.map(\.accountId)), budgetID: "demo-budget")
        let assistant = ConversationalAssistant(context: CoreRoutingContext(scope: sc), tools: FeatureTools(dataset: ds), ledger: ledger, planner: planner(ds))
        let archive = ConversationArchive(userID: ds.user.userId, datasetVersion: ds.datasetVersion)

        let keep = try await assistant.respond(to: "Keep the phone plan swap in my budget.", archive: archive)
        XCTAssertEqual(keep.actions.map(\.payload), [["idea_id": "s_phone", "keep": "true"]], keep.text)
        XCTAssertFalse(keep.text.lowercased().contains("i've kept") || keep.text.lowercased().contains("i have kept"), keep.text)

        let move = try await assistant.respond(to: "Move my Target purchases to Groceries.", archive: archive)
        XCTAssertEqual(move.actions.first?.kind, "recategorize", move.text)
        XCTAssertEqual(move.actions.first?.payload["category"], "Groceries")

        // Exactly as typed on the phone, lowercase store name included.
        let phone = try await assistant.respond(to: "Move my target purchase to groceries", archive: archive)
        XCTAssertEqual(phone.actions.first?.title, "Move 3 Target purchases to Groceries", phone.text)

        let chart = try await assistant.respond(to: "Show me my spending by category for September 2026.", archive: archive)
        XCTAssertTrue(chart.evidence.contains { $0.chart != nil }, "\(chart.evidence.map(\.provenance.resultId)) \(chart.text)")
    }
}

final class ChatTextTests: XCTestCase {
    func testDollarAmountsSurviveRendering() {
        let shown = String(ChatPanel.markdown("You spent **$784.50**, about $261.50 a month.").characters)
        XCTAssertEqual(shown, "You spent $784.50, about $261.50 a month.")
    }
}

final class ChatGroundingTests: XCTestCase {
    /// From the phone: the model sent "Laundry detergent" (from the budget snapshot) for "Move my target purchase to groceries".
    func testUsersWordsWinOverAModelSlip() async throws {
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let sc = CoreScope(userID: ds.user.userId, conversationID: "c", period: "2026-09", datasetVersion: ds.datasetVersion,
                           preferencesVersion: ds.user.preferencesVersion, accountIDs: Set(ds.accounts.map(\.accountId)))
        let planner = ChatActionPlanner(dataset: ds, requests: [], useHistory: true)
        let said = "Move my target purchase to groceries"
        let move = try await planner.plan(.init(kind: .recategorize, target: "Laundry detergent", value: "Groceries", utterance: said), scope: sc)
        XCTAssertEqual(move.title, "Move 3 Target purchases to Groceries")
        let noValue = try await planner.plan(.init(kind: .recategorize, target: "target", value: "Dining", utterance: said), scope: sc)
        XCTAssertEqual(noValue.payload["category"], "Groceries", "a category the user didn't say is replaced by the one they did")
        let keep = try await planner.plan(.init(kind: .keepIdea, target: "Pantry staples", utterance: "keep the phone plan swap"), scope: sc)
        XCTAssertEqual(keep.payload["idea_id"], "s_phone")
        // When the model's words are in the message, they're used as given.
        let tide = try await planner.plan(.init(kind: .recategorize, target: "Tide", value: "Groceries", utterance: "move the Tide purchase to groceries"), scope: sc)
        XCTAssertTrue(tide.title.contains("Tide detergent"), tide.title)
    }
}
