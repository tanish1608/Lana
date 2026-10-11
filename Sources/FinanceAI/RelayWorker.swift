import Foundation
import FWMCore

/// Runs paired relay jobs on the phone while Lana is open (PLAT-02). The relay never sees a model; it only delivers
/// `replyText` on the channel the message came in on.
public actor RelayWorker {
    /// Builds the trusted context for one job from local pairing and data. The host may await a review screen here,
    /// such as the receipt review that yields a `ReviewedSplit`. Throw `ToolError` to reply with its message.
    public typealias ContextProvider = @Sendable (RelayJob) async throws -> CoreRoutingContext
    private let client: RelayClient
    private let tools: any CoreToolExecuting
    private let router: any CoreIntentRouting
    private let contextFor: ContextProvider
    private let onAnswered: (@Sendable (RelayJob, AgentResult) async -> Void)?
    private var loop: Task<Void, Never>?

    /// `onAnswered` runs after the reply is posted, so the host can keep the turn in its chat history.
    public init(client: RelayClient, tools: any CoreToolExecuting, router: any CoreIntentRouting = CoreRouter(),
                contextFor: @escaping ContextProvider, onAnswered: (@Sendable (RelayJob, AgentResult) async -> Void)? = nil) {
        self.client = client; self.tools = tools; self.router = router; self.contextFor = contextFor; self.onAnswered = onAnswered
    }

    /// Scope over one owned dataset. The user ID comes from the dataset, not the envelope, so CoreAgent still rejects
    /// a job addressed to anyone else.
    public static func datasetContext(_ dataset: Dataset, period: String) -> ContextProvider {
        { job in
            CoreRoutingContext(scope: CoreScope(userID: dataset.user.userId, conversationID: job.envelope.conversationId,
                period: period, datasetVersion: dataset.datasetVersion, preferencesVersion: dataset.user.preferencesVersion,
                accountIDs: Set(dataset.accounts.map(\.accountId)), receiptIDs: Set((dataset.receipts ?? []).map(\.receiptId)),
                contactIDs: Set((dataset.contacts ?? []).map(\.contactId))))
        }
    }

    /// Handles at most one job. Returns the posted result, or nil when none arrived within `wait` seconds.
    @discardableResult
    public func runOnce(wait: Int = 25) async throws -> AgentResult? {
        guard let job = try await client.nextJob(wait: wait) else { return nil }
        let result: AgentResult
        do {
            let agent = CoreAgent(context: try await contextFor(job), router: router, tools: tools)
            result = try await agent.process(job.envelope, jobID: job.jobId).result
        } catch let error as ToolError {
            result = AgentResult(jobId: job.jobId, replyText: error.userMessage)
        } catch is CancellationError {
            // The lease runs out and the relay hands the job out again.
            throw CancellationError()
        } catch {
            result = AgentResult(jobId: job.jobId, replyText: "Lana could not finish that on the phone. Open the app to try again.")
        }
        // If this throws, the job stays leased and comes back later; the relay accepts a repeated result once.
        try await client.postResult(result)
        await onAnswered?(job, result)
        return result
    }

    /// Long-polls until `stop()`. Network failures back off up to 30 seconds.
    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.poll() }
    }

    public func stop() { loop?.cancel(); loop = nil }

    private func poll() async {
        var delay = 1
        while !Task.isCancelled {
            do { try await runOnce(); delay = 1 } catch {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }
}
