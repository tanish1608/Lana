import Foundation

/// Supplied by the authenticated host, never extracted from a prompt.
public struct UserContext: Codable, Sendable, Equatable {
    public let userID: String
    public let sessionID: UUID
    public init(userID: String, sessionID: UUID = UUID()) {
        self.userID = userID
        self.sessionID = sessionID
    }
}

public enum FinanceIntent: String, Codable, Sendable, CaseIterable {
    case netWorth, spending, budget, forecast, subscriptions, groceries, bills
    case proposeCancellation
    case unknown
}

public struct FinanceRequest: Codable, Sendable, Equatable {
    public let intent: FinanceIntent
    public let target: String?
    public init(intent: FinanceIntent, target: String? = nil) {
        self.intent = intent
        self.target = target
    }
}

public enum RoutingSource: String, Codable, Sendable {
    case onDevice, deterministicFallback, cloudRelay
}

public struct RoutedRequest: Sendable, Equatable {
    public let request: FinanceRequest
    public let source: RoutingSource
    /// A sanitized status message; never contains raw prompts or secrets.
    public let notice: String?
    public init(request: FinanceRequest, source: RoutingSource, notice: String? = nil) {
        self.request = request
        self.source = source
        self.notice = notice
    }
}

public protocol IntentRouting: Sendable {
    func route(_ text: String) async throws -> RoutedRequest
}

/// Financial calculations and display text come from the adapter, not an LLM.
public struct FinanceResult: Codable, Sendable, Equatable {
    public let summary: String
    public let evidence: [String]
    public let proposedAction: ProposedAction?
    public init(summary: String, evidence: [String] = [], proposedAction: ProposedAction? = nil) {
        self.summary = summary
        self.evidence = evidence
        self.proposedAction = proposedAction
    }
}

public enum ActionKind: String, Codable, Sendable {
    case cancelSubscription
}

/// Returned by the trusted adapter after resolving an exact target in the user's data.
/// Human-facing label must include any price/terms that matter for confirmation.
public struct ProposedAction: Codable, Sendable, Equatable {
    public let kind: ActionKind
    public let targetID: String
    public let confirmationSummary: String
    /// Adapter must reject stale versions at execution time (no changed terms).
    public let expectedVersion: String
    public init(kind: ActionKind, targetID: String, confirmationSummary: String, expectedVersion: String) {
        self.kind = kind
        self.targetID = targetID
        self.confirmationSummary = confirmationSummary
        self.expectedVersion = expectedVersion
    }
}

public struct ConfirmedAction: Codable, Sendable, Equatable {
    public let id: UUID
    public let context: UserContext
    public let proposal: ProposedAction
    public let confirmedAt: Date
}

public protocol FinanceToolProviding: Sendable {
    /// Read-only, including proposeCancellation. Must scope every query to context.userID.
    func query(_ request: FinanceRequest, context: UserContext) async throws -> FinanceResult
    /// Must be idempotent by action.id, enforce user scope and expectedVersion,
    /// and return a fresh forecast after changing state.
    func execute(_ action: ConfirmedAction) async throws -> FinanceResult
}

public protocol ActionAuthenticating: Sendable {
    func authenticate(reason: String) async throws
}

public enum FinanceAIError: Error, LocalizedError, Sendable, Equatable {
    case invalidInput, unavailable(String), confirmationRequired, expiredConfirmation
    case actionNotFound, actionAlreadyHandled, authenticationFailed, invalidSecret
    case invalidConfiguration, invalidReceipt, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Enter a request of 1–2,000 characters."
        case .unavailable(let reason): reason
        case .confirmationRequired: "Confirm this specific action with YES."
        case .expiredConfirmation: "This confirmation expired. Request a fresh proposal."
        case .actionNotFound: "This action does not belong to the current session."
        case .actionAlreadyHandled: "This action has already been handled."
        case .authenticationFailed: "Device authentication was not completed."
        case .invalidSecret: "The secret or one-time-code settings are invalid."
        case .invalidConfiguration: "The integration configuration is invalid."
        case .invalidReceipt: "The receipt draft could not be validated. Review the original image."
        case .cancelled: "The operation was cancelled."
        }
    }
}
