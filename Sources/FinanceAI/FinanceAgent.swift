import Foundation

public struct PendingConfirmation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let proposal: ProposedAction
    public let expiresAt: Date
}

public enum ActionStatus: String, Codable, Sendable { case proposed, authenticating, executing, succeeded, failed, declined, expired }
public struct ActionAuditEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let proposal: ProposedAction
    public let status: ActionStatus
    public let updatedAt: Date
}

public struct AgentReply: Sendable, Equatable {
    public let text: String
    public let source: RoutingSource
    public let notice: String?
    public let evidence: [String]
    public let confirmation: PendingConfirmation?
}

/// One instance per authenticated user session. The model cannot execute mutations,
/// read the vault, choose a user ID, or grant itself confirmation.
public actor FinanceAgent {
    private let context: UserContext
    private let router: any IntentRouting
    private let tools: any FinanceToolProviding
    private let authenticator: any ActionAuthenticating
    private let now: @Sendable () -> Date
    private var actions: [UUID: ActionAuditEntry] = [:]
    private var pending: [UUID: PendingConfirmation] = [:]

    public init(context: UserContext, router: any IntentRouting, tools: any FinanceToolProviding,
                authenticator: any ActionAuthenticating, now: @escaping @Sendable () -> Date = { Date() }) {
        self.context = context
        self.router = router
        self.tools = tools
        self.authenticator = authenticator
        self.now = now
    }

    public func receive(_ text: String) async throws -> AgentReply {
        let routed = try await router.route(text)
        guard routed.request.intent != .unknown else {
            return AgentReply(text: "Ask one question about your net worth, spending, budget, forecast, subscriptions, groceries, or bills. To cancel, name the subscription.", source: routed.source, notice: routed.notice, evidence: [], confirmation: nil)
        }
        let result = try await tools.query(routed.request, context: context)
        var confirmation: PendingConfirmation?
        if let proposal = result.proposedAction {
            // Only a cancellation request can create a cancellation confirmation.
            guard routed.request.intent == .proposeCancellation,
                  !proposal.targetID.isEmpty, !proposal.expectedVersion.isEmpty,
                  !proposal.confirmationSummary.isEmpty else { throw FinanceAIError.invalidConfiguration }
            let id = UUID()
            let timestamp = now()
            confirmation = PendingConfirmation(id: id, proposal: proposal, expiresAt: timestamp.addingTimeInterval(300))
            pending[id] = confirmation
            actions[id] = ActionAuditEntry(id: id, proposal: proposal, status: .proposed, updatedAt: timestamp)
        }
        return AgentReply(text: result.summary, source: routed.source, notice: routed.notice,
                          evidence: result.evidence, confirmation: confirmation)
    }

    /// Invoke only from an explicit human confirmation UI / matching chat YES.
    /// An ID from a different FinanceAgent instance is always rejected.
    public func confirm(actionID: UUID, userText: String) async throws -> FinanceResult {
        guard userText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES" else {
            throw FinanceAIError.confirmationRequired
        }
        guard let entry = actions[actionID] else { throw FinanceAIError.actionNotFound }
        guard entry.status == .proposed, let confirmation = pending[actionID] else {
            throw FinanceAIError.actionAlreadyHandled
        }
        guard now() < confirmation.expiresAt else {
            update(actionID, proposal: entry.proposal, status: .expired)
            pending.removeValue(forKey: actionID)
            throw FinanceAIError.expiredConfirmation
        }
        // Reserve before suspension so a concurrent YES cannot execute twice.
        update(actionID, proposal: entry.proposal, status: .authenticating)
        do {
            try await authenticator.authenticate(reason: entry.proposal.confirmationSummary)
            try Task.checkCancellation()
            // Decline or expiry while the authentication prompt was visible wins.
            guard actions[actionID]?.status == .authenticating else { throw FinanceAIError.actionAlreadyHandled }
            guard now() < confirmation.expiresAt else { throw FinanceAIError.expiredConfirmation }
            update(actionID, proposal: entry.proposal, status: .executing)
            let result = try await tools.execute(ConfirmedAction(id: actionID, context: context,
                                      proposal: entry.proposal, confirmedAt: now()))
            update(actionID, proposal: entry.proposal, status: .succeeded)
            pending.removeValue(forKey: actionID)
            return result
        } catch {
            if actions[actionID]?.status != .declined {
                update(actionID, proposal: entry.proposal, status: error as? FinanceAIError == .expiredConfirmation ? .expired : .failed)
            }
            pending.removeValue(forKey: actionID)
            // On ambiguous adapter failure, never auto-retry a mutation. The adapter
            // must reconcile via its durable idempotency key and audit storage.
            throw error
        }
    }

    public func decline(actionID: UUID) throws {
        guard let entry = actions[actionID] else { throw FinanceAIError.actionNotFound }
        guard entry.status == .proposed || entry.status == .authenticating else { throw FinanceAIError.actionAlreadyHandled }
        update(actionID, proposal: entry.proposal, status: .declined)
        pending.removeValue(forKey: actionID)
    }

    public func auditLog() -> [ActionAuditEntry] {
        actions.values.sorted { $0.updatedAt < $1.updatedAt }
    }
    private func update(_ id: UUID, proposal: ProposedAction, status: ActionStatus) {
        actions[id] = ActionAuditEntry(id: id, proposal: proposal, status: status, updatedAt: now())
    }
}
