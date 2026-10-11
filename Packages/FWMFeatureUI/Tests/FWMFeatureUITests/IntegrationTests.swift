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
        let assistant = ConversationalAssistant(context: CoreRoutingContext(scope: scope(ds)), tools: FeatureTools(dataset: ds))
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

    func testRelayCallIsStoredLikeAnInAppChat() async throws {
        let ds = try XCTUnwrap(DemoStore.repoSeed()).dataset
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = await LanaChatController(dataset: ds, directory: dir)
        func job(_ id: String, _ text: String) throws -> RelayJob {
            let json = #"{"job_id":"\#(id)","envelope":{"event_id":"evt_\#(id)","conversation_id":"call_test","paired_user_id":"user_ashwin","channel":"sms","received_at":"2026-10-11T15:31:00-07:00","text":"\#(text)","attachments":[]}}"#
            return try FWMJSON.decoder.decode(RelayJob.self, from: Data(json.utf8))
        }
        await chat.recordRelay(try job("job_1", "How did September go?"), AgentResult(jobId: "job_1", replyText: "September 2026: income $4,800."))
        await chat.recordRelay(try job("job_2", "What can I swap to save money?"), AgentResult(jobId: "job_2", replyText: "Saves $150 a month."))
        let saved = try await ConversationStore(directory: dir).load(userID: ds.user.userId)
        XCTAssertEqual(saved.count, 1, "both turns of one call land in one chat")
        XCTAssertEqual(saved[0].title, "Call · How did September go?")
        XCTAssertEqual(saved[0].messages.map(\.role), [.user, .assistant, .user, .assistant])
        let listed = await chat.savedChats.map(\.id)
        XCTAssertEqual(listed, [saved[0].id], "History shows it without a relaunch")
    }
}
