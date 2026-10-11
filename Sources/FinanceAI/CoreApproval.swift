import Foundation
import Security
import FWMCore

public enum CoreActionKind: Sendable { case budgetPlan, reimbursementRequests }
public struct CoreActionProposal: Sendable {
    public let actionID: String
    public let kind: CoreActionKind
    public let payloadVersion: String
    public let summary: String
    public init(actionID: String, kind: CoreActionKind, payloadVersion: String, summary: String) {
        self.actionID = actionID; self.kind = kind; self.payloadVersion = payloadVersion; self.summary = summary
    }
}
public struct CorePendingAction: Sendable {
    public let proposal: CoreActionProposal
    public let expiresAt: Date
}
public struct CoreActionAuthorization: Sendable {
    public let proposal: CoreActionProposal
    public let scope: CoreScope
    public let issuedAt: Date
    public let expiresAt: Date
    /// One-time capability for the trusted adapter; never sent to a model or included in logs.
    public let token: String
}
public protocol CoreActionCommitting: Sendable {
    /// Resolve the stored, owned proposal and its current payload/state version.
    func currentVersion(for proposal: CoreActionProposal, scope: CoreScope) async throws -> String
    /// Persist action-ID idempotency, validate authorization and version again atomically,
    /// then commit/send. A matching prior success returns its stored result.
    func commit(_ call: ToolCall, authorization: CoreActionAuthorization) async throws -> CoreToolOutput
}

/// Host-only approval gate. Models cannot invoke stage/approve through CoreAgent.
/// Stage only trusted engine proposals already stored by the owning adapter.
public actor CoreApprovalGate {
    private struct Entry {
        let pending: CorePendingAction
        var status: ActionStatus
    }
    private let scope: CoreScope
    private let authenticator: any ActionAuthenticating
    private let adapter: any CoreActionCommitting
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    public init(scope: CoreScope, authenticator: any ActionAuthenticating = DeviceOwnerAuthenticator(),
                adapter: any CoreActionCommitting, now: @escaping @Sendable () -> Date = { Date() }) {
        self.scope = scope; self.authenticator = authenticator; self.adapter = adapter; self.now = now
    }
    public func stage(_ proposal: CoreActionProposal) throws -> CorePendingAction {
        guard !scope.userID.isEmpty, !scope.conversationID.isEmpty else { throw ToolError(.authRequired, "Sign in first.") }
        guard !proposal.actionID.isEmpty, !proposal.payloadVersion.isEmpty,
              !proposal.summary.isEmpty, proposal.summary.count <= 500 else {
            throw ToolError(.invalidArguments, "The action proposal is incomplete.")
        }
        guard entries[proposal.actionID] == nil else { throw ToolError(.invalidArguments, "This proposal was already staged. Refresh the action.") }
        let pending = CorePendingAction(proposal: proposal, expiresAt: now().addingTimeInterval(300))
        entries[proposal.actionID] = Entry(pending: pending, status: .proposed)
        return pending
    }
    public func approve(actionID: String, humanResponse: String) async throws -> CoreToolOutput {
        guard humanResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES" else {
            throw ToolError(.authRequired, "Confirm the displayed action with YES.")
        }
        guard let entry = entries[actionID], entry.status == .proposed else {
            throw ToolError(.authRequired, "There is no pending approval for this action in this session.")
        }
        guard now() < entry.pending.expiresAt else {
            entries[actionID]?.status = .expired
            throw ToolError(.staleData, "Approval expired. Preview the action again.")
        }
        entries[actionID]?.status = .authenticating
        do {
            try await authenticator.authenticate(reason: entry.pending.proposal.summary)
            try Task.checkCancellation()
            let version = try await adapter.currentVersion(for: entry.pending.proposal, scope: scope)
            try Task.checkCancellation()
            guard entries[actionID]?.status == .authenticating else { throw ToolError(.authRequired, "Approval was declined.") }
            guard now() < entry.pending.expiresAt, version == entry.pending.proposal.payloadVersion else {
                throw ToolError(.staleData, "The action changed or expired. Preview it again before approving.")
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ToolError(.providerUnavailable, "Could not create an approval capability.")
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            let authorization = CoreActionAuthorization(proposal: entry.pending.proposal, scope: scope,
                issuedAt: now(), expiresAt: entry.pending.expiresAt, token: token)
            let call: ToolCall
            switch entry.pending.proposal.kind {
            case .budgetPlan: call = .commitBudgetPlan(actionId: actionID, approvalToken: token)
            case .reimbursementRequests: call = .dispatchRequests(actionId: actionID, approvalToken: token)
            }
            entries[actionID]?.status = .executing
            let output = try await adapter.commit(call, authorization: authorization)
            entries[actionID]?.status = .succeeded
            return output
        } catch {
            if entries[actionID]?.status != .declined { entries[actionID]?.status = .failed }
            throw error
        }
    }
    public func decline(actionID: String) throws {
        guard let entry = entries[actionID], entry.status == .proposed || entry.status == .authenticating else {
            throw ToolError(.invalidArguments, "This action is no longer awaiting approval.")
        }
        entries[actionID]?.status = .declined
    }
    public func status(actionID: String) -> ActionStatus? { entries[actionID]?.status }
}
