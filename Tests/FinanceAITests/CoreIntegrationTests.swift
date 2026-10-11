import Foundation
import Testing
import FWMCore
@testable import FinanceAI

private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/seed-v1.json")
private func loadFixture() throws -> Dataset { try Dataset.load(from: fixtureURL) }
private func scope(_ ds: Dataset) -> CoreScope {
    .init(userID: ds.user.userId, conversationID: "conversation-1", period: "2026-09",
          datasetVersion: ds.datasetVersion, preferencesVersion: ds.user.preferencesVersion,
          accountIDs: Set(ds.accounts.map(\.accountId)), receiptIDs: Set((ds.receipts ?? []).map(\.receiptId)),
          attachmentIDs: ["local-image-1"], contactIDs: Set((ds.contacts ?? []).map(\.contactId)),
          receiptItemIDs: Set(ds.receipts?.first?.items.map(\.itemId) ?? []), budgetID: "budget-1")
}
private func envelope(text: String, event: String = UUID().uuidString, user: String = "user_ashwin") throws -> MessageEnvelope {
    let data = try JSONSerialization.data(withJSONObject: ["event_id": event, "conversation_id": "conversation-1",
        "paired_user_id": user, "channel": "app", "received_at": "2026-10-11T12:00:00-07:00", "text": text, "attachments": []])
    return try FWMJSON.decoder.decode(MessageEnvelope.self, from: data)
}
@Test func canonicalMoneyHasExactGoldenNumbersAndProvenance() async throws {
    let ds = try loadFixture()
    let agent = CoreAgent(context: .init(scope: scope(ds)), tools: CoreDatasetTools(dataset: ds))
    let result = try await agent.process(envelope(text: "Where is my money going?"), jobID: "job-1").result
    #expect(result.replyText.contains("$4,800.00"))
    #expect(result.replyText.contains("$3,150.00"))
    #expect(result.replyText.contains("$11,550.00"))
    #expect(result.provenance?.resultId == "mv:seed-v1:2026-09:all")
    #expect(result.cardId == result.provenance?.resultId)
    #expect(result.jobId == "job-1")
}
@Test func canonicalSplitUsesReviewedAssignments() async throws {
    let ds = try loadFixture()
    let split = ReviewedSplit(receiptID: "rcpt_dinner_1011", payerID: "c_ashwin", assignments:
        ["it_1": ["c_tanish"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin", "c_tanish", "c_aryan"]])
    let agent = CoreAgent(context: .init(scope: scope(ds), reviewedSplit: split), tools: CoreDatasetTools(dataset: ds))
    let result = try await agent.process(envelope(text: "Split the reviewed receipt"), jobID: "job-2").result
    #expect(result.replyText.contains("$28.60"))
    #expect(result.replyText.contains("$36.40"))
    #expect(result.replyText.contains("$44.20"))
    #expect(result.replyText.contains("$80.60"))
    #expect(result.replyText.contains("No requests sent"))
    #expect(result.provenance?.datasetVersion == "seed-v1")
}
@Test func canonicalRejectsUnpairedIdentity() async throws {
    let ds = try loadFixture()
    let agent = CoreAgent(context: .init(scope: scope(ds)), tools: CoreDatasetTools(dataset: ds))
    do { _ = try await agent.process(envelope(text: "money", user: "someone-else"), jobID: "j"); Issue.record("Expected scope rejection") }
    catch let error as ToolError { #expect(error.code == .authRequired) }
}
@Test func canonicalRejectsModelMutationAndOutOfScopeIDs() throws {
    let s = scope(try loadFixture())
    for call in [ToolCall.commitBudgetPlan(actionId: "x", approvalToken: "model-forged"), .dispatchRequests(actionId: "x", approvalToken: "model-forged")] {
        do { try CoreToolValidator.validateRead(call, scope: s); Issue.record("Expected auth rejection") }
        catch let error as ToolError { #expect(error.code == .authRequired) }
    }
    #expect(throws: ToolError.self) { try CoreToolValidator.validateRead(.getMoneyView(period: "2026-09", accountFilter: ["other-user-account"]), scope: s) }
    #expect(throws: ToolError.self) { try CoreToolValidator.validateRead(.getSwapMemory(userId: "other-user", eligibleGroups: []), scope: s) }
    #expect(throws: ToolError.self) { try CoreToolValidator.validateRead(.extractReceipt(localAttachmentId: "remote-image"), scope: s) }
}
@Test func strictArgumentsAvoidInvalidMonthAndMoneyParsing() throws {
    #expect(CoreRouter.validPeriod("2026-09"))
    #expect(!CoreRouter.validPeriod("2026-99"))
    #expect(!CoreRouter.validPeriod("٢٠٢٦-٠٩"))
    #expect(try CoreRouter.savingsCents(in: "save $150.25 more") == 15_025)
    #expect(try CoreRouter.savingsCents(in: "save $1,000 more") == 100_000)
    #expect(try CoreRouter.savingsCents(in: "budget 2026-09") == 0)
    for text in ["save $10.999", "save $1,00", "save - $150", "save $150 or $250", "save $99999999999999999999", "save 150"] {
        #expect(throws: ToolError.self) { try CoreRouter.savingsCents(in: text) }
    }
}
@Test func unknownAdaptersDoNotReturnFakeSuccess() async throws {
    let ds = try loadFixture()
    do { _ = try await CoreDatasetTools(dataset: ds).query(.proposeBudget(period: "2026-09", extraSavingsCents: 15_000), scope: scope(ds)); Issue.record("Expected unavailable adapter") }
    catch let error as ToolError { #expect(error.code == .providerUnavailable) }
}
private actor CountingCoreTools: CoreToolExecuting {
    private var count = 0
    func query(_ call: ToolCall, scope: CoreScope) async throws -> CoreToolOutput {
        count += 1
        try await Task.sleep(for: .milliseconds(20))
        return .init(replyText: "Source result", provenance: .init(resultId: "r", datasetVersion: scope.datasetVersion,
                    dataMode: .fixture, asOf: "2026-10-11", sourceIds: ["fixture"], engineVersion: "test"))
    }
    func calls() -> Int { count }
}
@Test func relayDuplicateEventsAreCoalescedAndConflictingReplayRejected() async throws {
    let tools = CountingCoreTools()
    let agent = CoreAgent(context: .init(scope: scope(try loadFixture())), tools: tools)
    let event = try envelope(text: "money", event: "same-event")
    async let first = agent.process(event, jobID: "job-a")
    async let second = agent.process(event, jobID: "job-b")
    let results = try await [first, second]
    #expect(results.map(\.result.jobId) == ["job-a", "job-b"])
    #expect(await tools.calls() == 1)
    do { _ = try await agent.process(envelope(text: "budget", event: "same-event"), jobID: "job-c"); Issue.record("Expected replay rejection") }
    catch let error as ToolError { #expect(error.code == .invalidArguments) }
}

private struct CoreTestAuth: ActionAuthenticating { func authenticate(reason: String) async throws {} }
private actor TestCommitAdapter: CoreActionCommitting {
    var version = "v1"
    private var commits = 0
    func currentVersion(for proposal: CoreActionProposal, scope: CoreScope) async throws -> String { version }
    func commit(_ call: ToolCall, authorization: CoreActionAuthorization) async throws -> CoreToolOutput {
        guard case .commitBudgetPlan(let id, let token) = call,
              id == authorization.proposal.actionID, token == authorization.token, token.count == 64 else {
            throw ToolError(.authRequired, "Invalid capability")
        }
        commits += 1
        try await Task.sleep(for: .milliseconds(20))
        return .init(replyText: "Fixture plan committed")
    }
    func changeVersion() { version = "v2" }
    func count() -> Int { commits }
}
@Test func canonicalApprovalCannotExecuteTwice() async throws {
    let adapter = TestCommitAdapter()
    let gate = CoreApprovalGate(scope: scope(try loadFixture()), authenticator: CoreTestAuth(), adapter: adapter)
    _ = try await gate.stage(.init(actionID: "action-1", kind: .budgetPlan, payloadVersion: "v1", summary: "Commit reviewed plan"))
    do { _ = try await gate.approve(actionID: "action-1", humanResponse: "maybe"); Issue.record("Expected auth rejection") }
    catch let error as ToolError { #expect(error.code == .authRequired) }
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<5 { group.addTask { (try? await gate.approve(actionID: "action-1", humanResponse: "YES")) != nil } }
        var successes = 0
        for await success in group { if success { successes += 1 } }
        #expect(successes == 1)
    }
    #expect(await adapter.count() == 1)
    #expect(await gate.status(actionID: "action-1") == .succeeded)
}
@Test func changedProposalRequiresNewApproval() async throws {
    let adapter = TestCommitAdapter()
    let gate = CoreApprovalGate(scope: scope(try loadFixture()), authenticator: CoreTestAuth(), adapter: adapter)
    _ = try await gate.stage(.init(actionID: "action-1", kind: .budgetPlan, payloadVersion: "v1", summary: "Commit reviewed plan"))
    await adapter.changeVersion()
    do { _ = try await gate.approve(actionID: "action-1", humanResponse: "YES"); Issue.record("Expected stale proposal rejection") }
    catch let error as ToolError { #expect(error.code == .staleData) }
    #expect(await adapter.count() == 0)
}

/// Deliberately ignores cancellation to emulate an uncooperative provider SDK.
private actor SuspendedCoreTools: CoreToolExecuting {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var count = 0
    func query(_ call: ToolCall, scope: CoreScope) async throws -> CoreToolOutput {
        count += 1
        await withCheckedContinuation { continuation in
            pending = continuation
            observer?.resume()
            observer = nil
        }
        return .init(replyText: "Source result", provenance: .init(resultId: "r", datasetVersion: scope.datasetVersion,
            dataMode: .fixture, asOf: "2026-10-11", sourceIds: ["fixture"], engineVersion: "test"))
    }
    func waitForQuery() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { let continuation = pending; pending = nil; continuation?.resume() }
    func calls() -> Int { count }
}
@Test func canceledRelayJobCannotPublishLateProviderResultAndCanRetry() async throws {
    let tools = SuspendedCoreTools()
    let agent = CoreAgent(context: .init(scope: scope(try loadFixture())), tools: tools)
    let event = try envelope(text: "money", event: "canceled-event")
    let first = Task { try await agent.process(event, jobID: "job-canceled") }
    await tools.waitForQuery()
    await agent.cancel(eventID: event.eventId)
    await tools.release()
    do { _ = try await first.value; Issue.record("Canceled result was published") }
    catch is CancellationError {}
    let retry = Task { try await agent.process(event, jobID: "job-retry") }
    await tools.waitForQuery()
    await tools.release()
    #expect(try await retry.value.result.jobId == "job-retry")
    #expect(await tools.calls() == 2)
}

private actor SuspendedVersionAdapter: CoreActionCommitting {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var commits = 0
    func currentVersion(for proposal: CoreActionProposal, scope: CoreScope) async throws -> String {
        await withCheckedContinuation { continuation in
            pending = continuation
            observer?.resume()
            observer = nil
        }
        return "v1"
    }
    func commit(_ call: ToolCall, authorization: CoreActionAuthorization) async throws -> CoreToolOutput {
        commits += 1
        return .init(replyText: "Committed")
    }
    func waitForVersionCheck() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { let continuation = pending; pending = nil; continuation?.resume() }
    func count() -> Int { commits }
}
@Test func canceledApprovalDuringVersionCheckCannotCommit() async throws {
    let adapter = SuspendedVersionAdapter()
    let gate = CoreApprovalGate(scope: scope(try loadFixture()), authenticator: CoreTestAuth(), adapter: adapter)
    _ = try await gate.stage(.init(actionID: "action-canceled", kind: .budgetPlan, payloadVersion: "v1", summary: "Commit reviewed plan"))
    let approval = Task { try await gate.approve(actionID: "action-canceled", humanResponse: "YES") }
    await adapter.waitForVersionCheck()
    approval.cancel()
    await adapter.release()
    do { _ = try await approval.value; Issue.record("Canceled approval committed") }
    catch is CancellationError {}
    #expect(await adapter.count() == 0)
    #expect(await gate.status(actionID: "action-canceled") == .failed)
}

@Test func demoPhrasingsReachTheirTools() async throws {
    let ds = try loadFixture()
    let context = CoreRoutingContext(scope: scope(ds))
    let router = CoreRouter()
    guard case .getMoneyView(let period, _)? = try await router.route("How did September go?", context: context).tool else {
        Issue.record("How did September go? should read the money view"); return
    }
    #expect(period == "2026-09")
    guard case .suggestSwaps(let budget, _)? = try await router.route("What can I swap to save money?", context: context).tool else {
        Issue.record("What can I swap to save money? should suggest swaps"); return
    }
    #expect(budget == "budget-1")
    // Any other named month is still refused rather than guessed.
    await #expect(throws: ToolError.self) { try await router.route("How did March go?", context: context) }
}
