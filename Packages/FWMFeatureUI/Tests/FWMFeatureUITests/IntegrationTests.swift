import XCTest
import FinanceAI
import FWMCore
@testable import FWMFeatureUI

final class IntegrationTests: XCTestCase {
    func scope(_ dataset: Dataset) -> CoreScope {
        CoreScope(userID: dataset.user.userId, conversationID: "test", period: "2026-09", datasetVersion: dataset.datasetVersion,
            preferencesVersion: dataset.user.preferencesVersion, accountIDs: Set(dataset.accounts.map(\.accountId)),
            receiptIDs: Set((dataset.receipts ?? []).map(\.receiptId)), contactIDs: Set((dataset.contacts ?? []).map(\.contactId)),
            receiptItemIDs: Set((dataset.receipts ?? []).flatMap { $0.items.map(\.itemId) }),
            budgetID: "demo-budget")
    }
    func testChatBudgetMatchesSelectedScreenProjection() async throws {
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let selected: Set<String> = ["s_phone", "s_coffee", "h_transport"]
        let projection = try BudgetProjection.make(dataset: ds, period: "2026-09", accepted: selected, useHistory: false)
        XCTAssertEqual(projection.savingsCents, 6_000)
        XCTAssertEqual(projection.targets["Rent"], 160_000)
        let tools = FeatureTools(dataset: ds, accepted: selected, useHistory: false)
        let result = try await tools.query(.proposeBudget(period: "2026-09", extraSavingsCents: 15_000), scope: scope(ds))
        XCTAssertTrue(result.replyText.contains("$60.00"))
        XCTAssertTrue(result.replyText.contains("goal not met"))
        XCTAssertEqual(result.provenance?.datasetVersion, ds.datasetVersion)
        XCTAssertEqual(result.provenance?.evidenceIds, selected.sorted())
        XCTAssertFalse(result.replyText.contains("Pantry staples"))
    }
    func testUnpaidReimbursementsMatchUserReportedHomeState() async throws {
        let store = try XCTUnwrap(DemoStore.repoSeed())
        let example = try XCTUnwrap(store.splitExample)
        let tools = FeatureTools(dataset: store.dataset, requestStates: ["Tanish": "Paid (you said)"])
        let result = try await tools.query(.prepareSplit(receiptId: example.receiptId, assignments: example.assignments, payerId: example.payerId), scope: scope(store.dataset))
        XCTAssertTrue(result.replyText.contains("unpaid draft reimbursements are $44.20: Aryan: $44.20"))
        let home = store.unpaidRequests(["c_tanish": .paidReported]).reduce(0) { $0 + $1.amountCents }
        XCTAssertEqual(home, 4420)
    }
    func testAdapterRejectsForeignUserAndStaleSwapPreferences() async throws {
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let tools = FeatureTools(dataset: ds)
        let foreign = CoreScope(userID: "someone-else", conversationID: "test", period: "2026-09", datasetVersion: ds.datasetVersion, preferencesVersion: 1)
        do { _ = try await tools.query(.getMoneyView(period: "2026-09", accountFilter: nil), scope: foreign); XCTFail("Foreign user accepted") }
        catch let error as ToolError { XCTAssertEqual(error.code, .authRequired) }
        do { _ = try await tools.query(.suggestSwaps(budgetId: "demo-budget", preferencesVersion: ds.user.preferencesVersion + 1), scope: scope(ds)); XCTFail("Stale preferences accepted") }
        catch let error as ToolError { XCTAssertEqual(error.code, .staleData) }
    }
    func testReceiptReviewRejectsFractionsAndUnreconciledAmounts() throws {
        XCTAssertEqual(try ReceiptReviewAmounts.cents("$1,234.50"), 123450)
        for invalid in ["1.234", "-1", "nan", "", "1e5"] { XCTAssertThrowsError(try ReceiptReviewAmounts.cents(invalid)) }
        var receipt = try XCTUnwrap(DemoStore.repoSeed()?.dataset.receipts?.first)
        try ReceiptReviewAmounts.validate(receipt)
        receipt.tipCents += 1
        XCTAssertThrowsError(try ReceiptReviewAmounts.validate(receipt))
    }
    @MainActor func testReviewedReceiptBindsChatScopeAndInvalidatesOldEvidence() throws {
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let controller = LanaChatController(dataset: ds)
        let receipt = try XCTUnwrap(ds.receipts?.first)
        controller.review(receipt: receipt, assignments: ["it_1": ["c_tanish"]], payerID: "c_ashwin")
        XCTAssertEqual(controller.scope.receiptIDs, [receipt.receiptId])
        XCTAssertEqual(controller.scope.receiptItemIDs, Set(receipt.items.map(\.itemId)))
        XCTAssertNotEqual(controller.scope.datasetVersion, ds.datasetVersion)
        XCTAssertEqual(controller.archive?.datasetVersion, controller.scope.datasetVersion)
        let old = Provenance(resultId: "old", datasetVersion: ds.datasetVersion, dataMode: .fixture, asOf: ds.asOf, sourceIds: [], engineVersion: "test")
        controller.archive?.messages = [.init(role: .assistant, text: "Outdated $999 answer", evidence: [.init(text: "$999", provenance: old)])]
        let prompt = ConversationContext.prompt(request: "What now?", archive: try XCTUnwrap(controller.archive), scope: controller.scope)
        XCTAssertFalse(prompt.contains("999"))
    }
    func testActualIntegratedModelAnswersBudgetAndPDF() async throws {
        guard ProcessInfo.processInfo.environment["FWM_TEST_MODEL"] == "1" else { throw XCTSkip("Opt in with FWM_TEST_MODEL=1 on a model-ready Mac.") }
        XCTAssertEqual(OnDeviceRouter.status, .ready)
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        // As in the app: the ledger tool is offered alongside finance and readPDF.
        let ledger = try LocalLedger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await ledger.sync(ds)
        let assistant = ConversationalAssistant(context: CoreRoutingContext(scope: scope(ds)), tools: FeatureTools(dataset: ds), ledger: ledger)
        var archive = ConversationArchive(userID: ds.user.userId, datasetVersion: ds.datasetVersion)
        let hi = try await assistant.respond(to: "Hi", archive: archive)
        XCTAssertEqual(hi.source, .onDevice)
        XCTAssertFalse(hi.text.isEmpty)
        let budget = try await assistant.respond(to: "Use the budget tool. How much does my selected demo budget save each month?", archive: archive)
        XCTAssertEqual(budget.source, .onDevice)
        XCTAssertTrue(budget.evidence.contains { $0.text.contains("$150.00") && $0.provenance.resultId.hasPrefix("budget:") })
        XCTAssertTrue(budget.text.contains("150"), budget.text)
        archive.documents = [ChatDocument(name: "statement.pdf", pages: ["The statement savings balance is $220.00."])]
        let pdf = try await assistant.respond(to: "According to statement.pdf, what is the statement savings balance?", archive: archive)
        XCTAssertEqual(pdf.source, .onDevice)
        XCTAssertTrue(pdf.text.contains("220"), pdf.text)
        XCTAssertFalse(pdf.text.contains("650"), pdf.text)
    }
    func testActualModelAnswersFromTheLocalLedger() async throws {
        guard ProcessInfo.processInfo.environment["FWM_TEST_MODEL"] == "1" else { throw XCTSkip("Opt in with FWM_TEST_MODEL=1 on a model-ready Mac.") }
        XCTAssertEqual(OnDeviceRouter.status, .ready)
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let ledger = try LocalLedger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await ledger.sync(ds)
        try await ledger.record(.init(kind: "plan_adopted", summary: "Adopted the budget plan after Face ID"), userID: ds.user.userId)
        let assistant = ConversationalAssistant(context: CoreRoutingContext(scope: scope(ds)), tools: FeatureTools(dataset: ds), ledger: ledger)
        let archive = ConversationArchive(userID: ds.user.userId, datasetVersion: ds.datasetVersion)
        let tj = ds.transactions.filter { $0.merchant == "Trader Joe's" && $0.postedAt.hasPrefix("2026-09") }.reduce(0) { $0 - $1.signedAmountCents }
        let expected = CoreDatasetTools.money(tj)
        let spend = try await assistant.respond(to: "How much did I spend at Trader Joe's between 2026-09-01 and 2026-09-30?", archive: archive)
        XCTAssertEqual(spend.source, .onDevice)
        XCTAssertTrue(spend.evidence.contains { $0.provenance.resultId.hasPrefix("ledger:") && $0.text.contains(expected) }, "\(spend.evidence.map(\.text))")
        XCTAssertTrue(spend.text.contains(expected.replacingOccurrences(of: "$", with: "")), spend.text)
        let activity = try await assistant.respond(to: "What have I done in the app recently?", archive: archive)
        XCTAssertEqual(activity.source, .onDevice)
        XCTAssertTrue(activity.text.localizedCaseInsensitiveContains("adopt"), activity.text)
    }
}
