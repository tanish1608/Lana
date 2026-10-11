import Foundation
import FWMCore

public struct CoreToolOutput: Sendable {
    public let replyText: String
    public let provenance: Provenance?
    public let cardID: String?
    public let proposedActionID: String?
    /// Chart of this result's own figures, for the in-app chat.
    public let chart: ChatChart?
    public init(replyText: String, provenance: Provenance? = nil, cardID: String? = nil, proposedActionID: String? = nil, chart: ChatChart? = nil) {
        self.replyText = replyText; self.provenance = provenance
        self.cardID = cardID; self.proposedActionID = proposedActionID; self.chart = chart
    }
}

public protocol CoreToolExecuting: Sendable {
    /// Read-only tools / proposal creation. Scope again in the adapter before any query.
    func query(_ call: ToolCall, scope: CoreScope) async throws -> CoreToolOutput
}
public struct CoreAgentResponse: Sendable {
    public let result: AgentResult
    public let source: RoutingSource
    public let notice: String?
}

/// Authenticated v2 entry point for the app/relay. Preserves engine-derived text and
/// provenance instead of asking an LLM to rewrite financial figures.
public actor CoreAgent {
    private struct Processed: Sendable {
        let output: CoreToolOutput
        let source: RoutingSource
        let notice: String?
    }
    private struct InFlight {
        let id: UUID
        let envelope: MessageEnvelope
        let task: Task<Processed, any Error>
    }
    private let router: any CoreIntentRouting
    private let tools: any CoreToolExecuting
    private let context: CoreRoutingContext
    private var events: [String: InFlight] = [:]
    private var completedOrder: [String] = []
    public init(context: CoreRoutingContext, router: any CoreIntentRouting = CoreRouter(), tools: any CoreToolExecuting) {
        self.context = context; self.router = router; self.tools = tools
    }

    public func process(_ envelope: MessageEnvelope, jobID: String) async throws -> CoreAgentResponse {
        guard envelope.pairedUserId == context.scope.userID,
              envelope.conversationId == context.scope.conversationID else {
            throw ToolError(.authRequired, "This conversation is not paired with the current user.")
        }
        guard !envelope.eventId.isEmpty, !jobID.isEmpty else { throw ToolError(.invalidArguments, "The event/job identifier is missing.") }
        let work: InFlight
        if let existing = events[envelope.eventId] {
            guard existing.envelope == envelope else { throw ToolError(.invalidArguments, "A duplicate event has different content.") }
            work = existing
        } else {
            guard events.count < 256 else { throw ToolError(.providerUnavailable, "Too many requests are pending. Try again shortly.", retryable: true) }
            let context = self.context, router = self.router, tools = self.tools
            let task = Task {
                try Task.checkCancellation()
                guard let text = envelope.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolError(.invalidArguments, "Review the attachment or transcript, then submit a text request.")
                }
                let route = try await router.route(text, context: context)
                try Task.checkCancellation()
                guard let call = route.tool else {
                    return Processed(output: .init(replyText: route.clarification ?? "Please clarify your request."), source: route.source, notice: route.notice)
                }
                try CoreToolValidator.validateRead(call, scope: context.scope)
                let output = try await tools.query(call, scope: context.scope)
                try Task.checkCancellation()
                if let provenance = output.provenance {
                    guard provenance.datasetVersion == context.scope.datasetVersion, provenance.currency == "USD" else {
                        throw ToolError(.staleData, "The dataset changed. Refresh before requesting this result.")
                    }
                } else if Self.requiresProvenance(call) {
                    throw ToolError(.invalidArguments, "The financial tool did not supply source provenance.")
                }
                return Processed(output: output, source: route.source, notice: route.notice)
            }
            work = InFlight(id: UUID(), envelope: envelope, task: task)
            events[envelope.eventId] = work
        }
        do {
            let processed = try await work.task.value
            if events[envelope.eventId]?.id == work.id, !completedOrder.contains(envelope.eventId) {
                completedOrder.append(envelope.eventId)
            }
            // Bounded session-local dedupe. Relay must persist event/job dedupe too.
            while completedOrder.count > 128 { events.removeValue(forKey: completedOrder.removeFirst()) }
            let output = processed.output
            return CoreAgentResponse(result: AgentResult(jobId: jobID, replyText: output.replyText,
                  cardId: output.cardID, proposedActionId: output.proposedActionID, provenance: output.provenance),
                  source: processed.source, notice: processed.notice)
        } catch {
            // An older duplicate waiter must not remove a newly retried event.
            if events[envelope.eventId]?.id == work.id { events.removeValue(forKey: envelope.eventId) }
            throw error
        }
    }
    public func cancel(eventID: String) {
        events[eventID]?.task.cancel()
        // Keep the reservation until process unwinds; never run a replacement concurrently.
    }
    private static func requiresProvenance(_ call: ToolCall) -> Bool {
        switch call {
        case .getMoneyView, .proposeBudget, .suggestSwaps, .prepareSplit: true
        default: false
        }
    }
}

/// Implements only Aryan's already-landed engines. Inject budget/swap/provider
/// adapters through CoreToolExecuting when their owners land them; no fake success.
public struct CoreDatasetTools: CoreToolExecuting {
    private let dataset: Dataset
    public init(dataset: Dataset) { self.dataset = dataset }
    public func query(_ call: ToolCall, scope: CoreScope) async throws -> CoreToolOutput {
        guard dataset.user.userId == scope.userID, dataset.datasetVersion == scope.datasetVersion else {
            throw ToolError(.authRequired, "The loaded data does not belong to this session.")
        }
        try CoreToolValidator.validateRead(call, scope: scope)
        switch call {
        case .getMoneyView(let period, let filter):
            let result = try MoneyEngine.moneyView(dataset, period: period, accountFilter: filter)
            let flow = result.flow
            return .init(replyText: "\(period): income \(Self.money(flow.netIncomeCents)), expenses \(Self.money(flow.expensesCents)), savings \(Self.money(flow.toSavingsCents)), investments \(Self.money(flow.toInvestmentsCents)), retained cash \(Self.money(flow.retainedCashCents)). Net worth: \(Self.money(result.netWorthCents)). Data mode: \(result.provenance.dataMode.rawValue).",
                         provenance: result.provenance, cardID: result.provenance.resultId)
        case .prepareSplit(let receiptID, let assignments, let payerID):
            guard let receipt = dataset.receipts?.first(where: { $0.receiptId == receiptID }), let contacts = dataset.contacts else {
                throw ToolError(.invalidArguments, "The reviewed receipt is missing.")
            }
            let result = try SplitEngine.prepareSplit(receipt: receipt, assignments: assignments,
                payerId: payerID, contacts: contacts, datasetVersion: dataset.datasetVersion, dataMode: dataset.dataMode)
            let roster = Dictionary(uniqueKeysWithValues: contacts.map { ($0.contactId, $0.reviewedName) })
            let shares = result.shares.map { "\(roster[$0.contactId] ?? "Reviewed contact"): \(Self.money($0.totalCents))" }.joined(separator: "; ")
            return .init(replyText: "Reviewed split — \(shares). Outstanding reimbursements: \(Self.money(result.outstandingCents)). No requests sent. Data mode: \(result.provenance.dataMode.rawValue).",
                         provenance: result.provenance, cardID: result.provenance.resultId)
        default:
            throw ToolError(.providerUnavailable, "This tool's adapter has not been connected yet. Its owning lane will supply it.")
        }
    }
    public static func money(_ cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(cents) / 100)) ?? "USD amount unavailable"
    }
}
