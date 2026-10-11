import Foundation
import FWMCore

/// A small chart drawn under a chat reply. Built by deterministic tools from engine or ledger results, never from
/// numbers the model wrote, so a chart shows exactly the figures in its source.
public struct ChatChart: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable {
        /// Horizontal bars, one per label (categories, merchants, balances).
        case bars
        /// Vertical columns over time (months).
        case columns
        /// Two values per label, e.g. spending now versus the plan.
        case comparison
    }
    public struct Point: Codable, Sendable, Equatable {
        public var label: String
        public var cents: Int
        public var secondCents: Int?
        public init(label: String, cents: Int, secondCents: Int? = nil) { self.label = label; self.cents = cents; self.secondCents = secondCents }
    }
    public var title: String
    public var style: Style
    public var points: [Point]
    /// Names for `cents` and `secondCents` in a comparison.
    public var series: [String]?
    public init(title: String, style: Style, points: [Point], series: [String]? = nil) {
        self.title = title; self.style = style; self.points = points; self.series = series
    }
}

/// A change the chat proposes. Nothing happens until the user taps the card's confirm button; the host app then
/// re-validates the payload against current state and performs it (with device authentication where needed).
public struct ChatAction: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case proposed, done, cancelled, failed }
    public let id: UUID
    /// keep_idea, skip_idea, adopt_plan, mark_request, recategorize, open_screen, remove_account
    public let kind: String
    public let title: String
    public let detail: String
    /// Host-resolved identifiers (idea, contact, transaction or account IDs). Never model text.
    public let payload: [String: String]
    public let confirmLabel: String
    public let requiresAuthentication: Bool
    public var status: Status
    public var result: String?
    public init(kind: String, title: String, detail: String, payload: [String: String], confirmLabel: String, requiresAuthentication: Bool = false) {
        id = UUID(); self.kind = kind; self.title = title; self.detail = detail; self.payload = payload
        self.confirmLabel = confirmLabel; self.requiresAuthentication = requiresAuthentication; status = .proposed
    }
}

/// What the model asked for, in its own words. The host resolves `target` and `value` against real state.
public struct ChatActionRequest: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case keepIdea, skipIdea, adoptPlan, markPaid, markRequested, recategorize, openScreen, removeAccount }
    public var kind: Kind
    public var target: String?
    public var value: String?
    public var date: String?
    /// The user's own message. A planner prefers it when the model's `target` or `value` isn't in it, because a small
    /// model sometimes copies a name from the data snapshot instead of the request.
    public var utterance: String?
    public init(kind: Kind, target: String? = nil, value: String? = nil, date: String? = nil, utterance: String? = nil) {
        self.kind = kind; self.target = target; self.value = value; self.date = date; self.utterance = utterance
    }
}

/// Turns a model's request into a reviewable action card, or throws a ToolError whose message asks for clarification.
public protocol ChatActionPlanning: Sendable {
    func plan(_ request: ChatActionRequest, scope: CoreScope) async throws -> ChatAction
}
