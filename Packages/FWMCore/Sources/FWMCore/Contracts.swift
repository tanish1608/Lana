import Foundation

// Shared contracts from SRS v2 section 2. JSON on the wire is snake_case; use FWMJSON to encode/decode.

public enum FWMJSON {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

public enum DataMode: String, Codable, Sendable { case fixture, sandbox, live, cached }

/// CORE-01: every result carries where its numbers came from.
public struct Provenance: Codable, Sendable, Equatable {
    public var resultId: String
    public var datasetVersion: String
    public var dataMode: DataMode
    public var asOf: String
    public var currency: String
    public var sourceIds: [String]
    public var evidenceIds: [String]
    public var engineVersion: String

    public init(resultId: String, datasetVersion: String, dataMode: DataMode, asOf: String, currency: String = "USD",
                sourceIds: [String], evidenceIds: [String] = [], engineVersion: String) {
        self.resultId = resultId
        self.datasetVersion = datasetVersion
        self.dataMode = dataMode
        self.asOf = asOf
        self.currency = currency
        self.sourceIds = sourceIds
        self.evidenceIds = evidenceIds
        self.engineVersion = engineVersion
    }
}

public enum Channel: String, Codable, Sendable { case imessage, sms, app }

public struct AttachmentRef: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case image, audio, other }
    public var attachmentId: String
    public var kind: Kind
    public var mimeType: String?
    /// Relay URL the paired phone fetches the bytes from. Never a public URL.
    public var url: String?
}

/// What the relay hands the phone for each inbound message. The relay assigns identity.
public struct MessageEnvelope: Codable, Sendable, Equatable {
    public var eventId: String
    public var conversationId: String
    public var pairedUserId: String
    public var channel: Channel
    public var receivedAt: String
    public var text: String?
    public var attachments: [AttachmentRef]
}

/// What the phone hands back. The relay delivers reply_text (and the card, if any) on the same channel.
public struct AgentResult: Codable, Sendable, Equatable {
    public var jobId: String
    public var replyText: String
    public var cardId: String?
    public var proposedActionId: String?
    public var provenance: Provenance?

    public init(jobId: String, replyText: String, cardId: String? = nil, proposedActionId: String? = nil, provenance: Provenance? = nil) {
        self.jobId = jobId
        self.replyText = replyText
        self.cardId = cardId
        self.proposedActionId = proposedActionId
        self.provenance = provenance
    }
}

public enum ErrorCode: String, Codable, Sendable {
    case authRequired = "AUTH_REQUIRED"
    case staleData = "STALE_DATA"
    case ambiguousContact = "AMBIGUOUS_CONTACT"
    case receiptMismatch = "RECEIPT_MISMATCH"
    case providerUnavailable = "PROVIDER_UNAVAILABLE"
    case needsForeground = "NEEDS_FOREGROUND"
    case invalidArguments = "INVALID_ARGUMENTS"
    case unknownTool = "UNKNOWN_TOOL"
}

public struct ToolError: Error, Codable, Sendable, Equatable {
    public var code: ErrorCode
    public var retryable: Bool
    public var userMessage: String

    public init(_ code: ErrorCode, _ userMessage: String, retryable: Bool = false) {
        self.code = code
        self.userMessage = userMessage
        self.retryable = retryable
    }
}

/// CORE-03: the model proposes one of these. Anything else is rejected before it reaches an engine.
/// Wire format: {"tool": "get_money_view", "arguments": {...}}
/// The tool names and arguments are the shared contract (SRS section 2). The router and dispatcher (user scope,
/// state version, authorization) belong to Tanish. `parse` is a reference validator he can replace.
public enum ToolCall: Sendable, Equatable {
    case getMoneyView(period: String, accountFilter: [String]?)
    case proposeBudget(period: String, extraSavingsCents: Int)
    case getSwapMemory(userId: String, eligibleGroups: [String])
    case suggestSwaps(budgetId: String, preferencesVersion: Int)
    case extractReceipt(localAttachmentId: String)
    case prepareSplit(receiptId: String, assignments: [String: [String]], payerId: String)
    case commitBudgetPlan(actionId: String, approvalToken: String)
    case dispatchRequests(actionId: String, approvalToken: String)

    public static let allowlist = ["get_money_view", "propose_budget", "get_swap_memory", "suggest_swaps",
                                   "extract_receipt", "prepare_split", "commit_budget_plan", "dispatch_requests"]

    /// Parses model output. Unknown tools and malformed arguments become a ToolError, never a crash.
    public static func parse(_ data: Data) -> Result<ToolCall, ToolError> {
        struct Raw: Decodable { let tool: String; let arguments: [String: AnyJSON]? }
        guard let raw = try? FWMJSON.decoder.decode(Raw.self, from: data) else {
            return .failure(ToolError(.invalidArguments, "I couldn't read that request. Could you rephrase it?"))
        }
        guard allowlist.contains(raw.tool) else {
            return .failure(ToolError(.unknownTool, "I can't do that yet."))
        }
        let a = raw.arguments ?? [:]
        func str(_ k: String) -> String? { a[k]?.string }
        func int(_ k: String) -> Int? { a[k]?.int }
        let bad = ToolError(.invalidArguments, "Some details were missing. Could you say that again?")
        switch raw.tool {
        case "get_money_view":
            guard let p = str("period"), isPeriod(p) else { return .failure(bad) }
            return .success(.getMoneyView(period: p, accountFilter: a["account_filter"]?.stringArray))
        case "propose_budget":
            guard let p = str("period"), isPeriod(p), let x = int("extra_savings_cents"), x >= 0 else { return .failure(bad) }
            return .success(.proposeBudget(period: p, extraSavingsCents: x))
        case "get_swap_memory":
            guard let u = str("user_id"), let g = a["eligible_groups"]?.stringArray else { return .failure(bad) }
            return .success(.getSwapMemory(userId: u, eligibleGroups: g))
        case "suggest_swaps":
            guard let b = str("budget_id"), let v = int("preferences_version") else { return .failure(bad) }
            return .success(.suggestSwaps(budgetId: b, preferencesVersion: v))
        case "extract_receipt":
            guard let id = str("local_attachment_id") else { return .failure(bad) }
            return .success(.extractReceipt(localAttachmentId: id))
        case "prepare_split":
            guard let r = str("receipt_id"), let p = str("payer_id"), case .object(let o)? = a["assignments"] else { return .failure(bad) }
            var assignments: [String: [String]] = [:]
            for (k, v) in o {
                guard let ids = v.stringArray, !ids.isEmpty else { return .failure(bad) }
                assignments[k] = ids
            }
            return .success(.prepareSplit(receiptId: r, assignments: assignments, payerId: p))
        case "commit_budget_plan", "dispatch_requests":
            guard let act = str("action_id"), let tok = str("approval_token") else { return .failure(bad) }
            return .success(raw.tool == "commit_budget_plan" ? .commitBudgetPlan(actionId: act, approvalToken: tok) : .dispatchRequests(actionId: act, approvalToken: tok))
        default:
            return .failure(ToolError(.unknownTool, "I can't do that yet."))
        }
    }

    static func isPeriod(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil }
}

/// Minimal JSON value for loosely typed model arguments.
public enum AnyJSON: Decodable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([AnyJSON]), object([String: AnyJSON]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AnyJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: AnyJSON].self)) }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .number(let n) = self, n == n.rounded() { return Int(n) }; return nil }
    var stringArray: [String]? {
        guard case .array(let xs) = self else { return nil }
        let s = xs.compactMap(\.string)
        return s.count == xs.count ? s : nil
    }
}
