import Foundation
import FoundationModels
import FWMCore

/// Trusted host context; none of these IDs are chosen by the model.
public struct CoreScope: Sendable {
    public let userID: String
    public let conversationID: String
    public let period: String
    public let datasetVersion: String
    public let preferencesVersion: Int
    public let accountIDs: Set<String>
    public let receiptIDs: Set<String>
    public let attachmentIDs: Set<String>
    public let contactIDs: Set<String>
    public let receiptItemIDs: Set<String>
    public let budgetID: String?
    public let eligibleSwapGroups: Set<String>
    public init(userID: String, conversationID: String, period: String, datasetVersion: String,
                preferencesVersion: Int, accountIDs: Set<String> = [], receiptIDs: Set<String> = [],
                attachmentIDs: Set<String> = [], contactIDs: Set<String> = [], receiptItemIDs: Set<String> = [],
                budgetID: String? = nil, eligibleSwapGroups: Set<String> = []) {
        self.userID = userID; self.conversationID = conversationID; self.period = period
        self.datasetVersion = datasetVersion; self.preferencesVersion = preferencesVersion
        self.accountIDs = accountIDs; self.receiptIDs = receiptIDs; self.attachmentIDs = attachmentIDs
        self.contactIDs = contactIDs; self.receiptItemIDs = receiptItemIDs
        self.budgetID = budgetID; self.eligibleSwapGroups = eligibleSwapGroups
    }
}

public struct ReviewedSplit: Sendable {
    public let receiptID: String
    public let payerID: String
    public let assignments: [String: [String]]
    public init(receiptID: String, payerID: String, assignments: [String: [String]]) {
        self.receiptID = receiptID; self.payerID = payerID; self.assignments = assignments
    }
}

public struct CoreRoutingContext: Sendable {
    public let scope: CoreScope
    public let localAttachmentID: String?
    public let reviewedSplit: ReviewedSplit?
    public init(scope: CoreScope, localAttachmentID: String? = nil, reviewedSplit: ReviewedSplit? = nil) {
        self.scope = scope; self.localAttachmentID = localAttachmentID; self.reviewedSplit = reviewedSplit
    }
}

public struct CoreRoute: Sendable {
    public let tool: ToolCall?
    public let clarification: String?
    public let source: RoutingSource
    public let notice: String?
    public init(tool: ToolCall?, clarification: String? = nil, source: RoutingSource, notice: String? = nil) {
        self.tool = tool; self.clarification = clarification; self.source = source; self.notice = notice
    }
}
public protocol CoreIntentRouting: Sendable {
    func route(_ text: String, context: CoreRoutingContext) async throws -> CoreRoute
}

@Generable
private enum CoreModelIntent { case money, budget, swaps, receipt, split, clarify }
@Generable
private struct CoreModelDecision {
    @Guide(description: "One topic label: money for financial position and cash flow; budget for putting money aside; swaps for cheaper alternatives; receipt for reading receipt text; split for allocating a bill among people. Otherwise clarify.")
    var intent: CoreModelIntent
}

/// Canonical v2 router. Model classifies a family; host context supplies all object
/// identifiers, and deterministic input parsing supplies money/month arguments.
public struct CoreRouter: CoreIntentRouting {
    private let preferRules: Bool
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    public init(preferRules: Bool = true) { self.preferRules = preferRules }
    public func route(_ text: String, context: CoreRoutingContext) async throws -> CoreRoute {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 2_000 else { throw ToolError(.invalidArguments, "Ask one question of up to 2,000 characters.") }
        let words = Set(clean.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        // Unsupported side effects / attempted identity changes never reach inference.
        if !words.intersection(["cancel", "transfer", "send", "commit", "approve", "approval", "token", "password", "otp"]).isEmpty
            || clean.lowercased().contains("user_id") || clean.uppercased() == "YES" {
            return .init(tool: nil, clarification: "Use the specific action's review screen to approve changes. I can explain money, propose budgets or swaps, and prepare a reviewed receipt split.", source: .deterministicFallback)
        }
        let ruleIntent = rules(clean, words: words)
        if preferRules, let intent = ruleIntent { return try make(intent, text: clean, context: context, source: .deterministicFallback) }
        guard OnDeviceRouter.status == .ready else {
            if let intent = ruleIntent {
                return try make(intent, text: clean, context: context, source: .deterministicFallback, notice: OnDeviceRouter.status.description)
            }
            return .init(tool: nil, clarification: "Ask about your money, a budget, swaps, or a receipt split.", source: .deterministicFallback, notice: OnDeviceRouter.status.description)
        }
        let session = LanguageModelSession(model: SystemLanguageModel(useCase: .contentTagging), instructions: """
            Tag the topic of the input using one of the provided labels.
            Examples: 'How am I doing?' -> money. 'Explain my financial position' -> money.
            'Put aside $150 each month' -> budget. 'Compare cheaper options' -> swaps.
            'Read this receipt' -> receipt. 'Split the reviewed receipt' -> split.
            This is text classification, not advice, arithmetic, or action execution.
            If no single topic applies, use clarify.
            """
        )
        do {
            let response = try await session.respond(to: clean, generating: CoreModelDecision.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 80))
            try Task.checkCancellation()
            return try make(response.content.intent, text: clean, context: context, source: .onDevice)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            if let intent = ruleIntent {
                return try make(intent, text: clean, context: context, source: .deterministicFallback, notice: "Local inference failed; using offline rules.")
            }
            return .init(tool: nil, clarification: "I couldn't classify that locally. Ask one question about money, budgets, swaps, or receipts.", source: .deterministicFallback, notice: "Local inference unavailable.")
        }
    }
    private func rules(_ text: String, words: Set<String>) -> CoreModelIntent? {
        if !words.intersection(["not", "never", "dont", "don"]).isEmpty { return .clarify }
        // "What can I swap to save money?" asks for swaps; saving is the reason, not a second request.
        if !words.intersection(["swaps", "swap", "cheaper", "alternatives"]).isEmpty && words.isDisjoint(with: ["split", "receipt"]) { return .swaps }
        var intents: [CoreModelIntent] = []
        if words.contains("split") { intents.append(.split) }
        if words.contains("receipt") && !words.contains("split") { intents.append(.receipt) }
        if !words.intersection(["swaps", "swap", "cheaper", "alternatives"]).isEmpty { intents.append(.swaps) }
        if !words.intersection(["budget", "save", "saving", "savings"]).isEmpty || text.lowercased().contains("put aside") { intents.append(.budget) }
        if !words.intersection(["money", "spending", "spend", "spent", "income", "assets", "debts", "worth", "accounts"]).isEmpty
            || (!words.isDisjoint(with: Self.months) && !words.isDisjoint(with: ["how", "go", "went", "did", "look", "looking"]))
            || text.lowercased().hasPrefix("how am i doing") || text.lowercased().contains("financial position") { intents.append(.money) }
        return intents.count == 1 ? intents.first : intents.count > 1 ? .clarify : nil
    }
    private func make(_ intent: CoreModelIntent, text: String, context: CoreRoutingContext,
                      source: RoutingSource, notice: String? = nil) throws -> CoreRoute {
        let call: ToolCall
        switch intent {
        case .money: call = .getMoneyView(period: try Self.period(in: text, default: context.scope.period), accountFilter: nil)
        case .budget: call = .proposeBudget(period: try Self.period(in: text, default: context.scope.period), extraSavingsCents: try Self.savingsCents(in: text))
        case .swaps:
            guard let id = context.scope.budgetID else {
                return .init(tool: nil, clarification: "Prepare a budget first so swaps use the current plan and preferences.", source: source, notice: notice)
            }
            call = .suggestSwaps(budgetId: id, preferencesVersion: context.scope.preferencesVersion)
        case .receipt:
            guard let id = context.localAttachmentID else {
                return .init(tool: nil, clarification: "Choose a receipt image in the app first.", source: source, notice: notice)
            }
            call = .extractReceipt(localAttachmentId: id)
        case .split:
            guard let split = context.reviewedSplit else {
                return .init(tool: nil, clarification: "Review the receipt, payer, and item assignments before calculating shares.", source: source, notice: notice)
            }
            call = .prepareSplit(receiptId: split.receiptID, assignments: split.assignments, payerId: split.payerID)
        case .clarify:
            return .init(tool: nil, clarification: "Ask one question about your money, budget, swaps, or a reviewed receipt.", source: source, notice: notice)
        }
        try CoreToolValidator.validateRead(call, scope: context.scope)
        return .init(tool: call, source: source, notice: notice)
    }

    public static func validPeriod(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].count == 4 && parts[1].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
            && (Int(parts[0]).map { (1900...2200).contains($0) } ?? false)
            && (Int(parts[1]).map { (1...12).contains($0) } ?? false)
    }
    static func period(in text: String, default defaultPeriod: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\b[0-9]{4}-[0-9]{2}\b"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count <= 1 else { throw ToolError(.invalidArguments, "Choose one calendar month.") }
        let period = matches.first.flatMap { Range($0.range, in: text).map { String(text[$0]) } } ?? defaultPeriod
        guard validPeriod(period) else { throw ToolError(.invalidArguments, "Use a valid month such as 2026-09.") }
        // Avoid silently treating an unparsed named month as the current month.
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if matches.isEmpty, words.contains(where: months.contains) || text.lowercased().contains("last month") {
            // Naming the default period's own month is unambiguous: "How did September go?" while showing 2026-09.
            let named = Set(words.filter(months.contains))
            if named.count == 1, !text.lowercased().contains("last month"), let i = months.firstIndex(of: named.first!),
               defaultPeriod.hasSuffix(String(format: "-%02d", i + 1)) { return defaultPeriod }
            throw ToolError(.invalidArguments, "Specify the month as YYYY-MM, for example 2026-09.")
        }
        return period
    }
    /// Copies a literal $ amount; never asks the model to multiply dollars into cents.
    static func savingsCents(in text: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: #"\$([0-9]+(?:,[0-9]{3})*)(?:\.([0-9]{1,2}))?(?![0-9.,])"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count <= 1 else { throw ToolError(.invalidArguments, "Specify one extra monthly savings amount.") }
        guard let match = matches.first else {
            let periodRegex = try NSRegularExpression(pattern: #"\b[0-9]{4}-[0-9]{2}\b"#)
            let withoutPeriod = periodRegex.stringByReplacingMatches(in: text,
                range: NSRange(text.startIndex..., in: text), withTemplate: "")
            if text.contains("$") || withoutPeriod.contains(where: \.isNumber) {
                throw ToolError(.invalidArguments, "Write extra savings as one dollar amount, for example $150.")
            }
            return 0
        }
        let dollarsText = String(text[Range(match.range(at: 1), in: text)!]).replacingOccurrences(of: ",", with: "")
        let fractionText = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
        guard dollarsText.count <= 7, let dollars = Int(dollarsText) else {
            throw ToolError(.invalidArguments, "Extra savings amount is too large.")
        }
        let fraction = fractionText.isEmpty ? 0 : Int(fractionText)! * (fractionText.count == 1 ? 10 : 1)
        let cents = dollars * 100 + fraction
        let negative = text.range(of: #"[-−]\s*\$|\$\s*[-−]"#, options: .regularExpression) != nil
        guard cents <= 100_000_000, !negative else {
            throw ToolError(.invalidArguments, "Extra savings must be between $0 and $1,000,000.")
        }
        return cents
    }
}

public enum CoreToolValidator {
    public static func validateRead(_ call: ToolCall, scope: CoreScope) throws {
        guard !scope.userID.isEmpty, !scope.conversationID.isEmpty else { throw ToolError(.authRequired, "Sign in and pair this conversation.") }
        let invalid = ToolError(.invalidArguments, "The tool arguments are invalid or outside the current user scope.")
        switch call {
        case .getMoneyView(let period, let filter):
            guard CoreRouter.validPeriod(period), filter.map({ !$0.isEmpty && Set($0).isSubset(of: scope.accountIDs) }) ?? true else { throw invalid }
        case .proposeBudget(let period, let amount):
            guard CoreRouter.validPeriod(period), (0...100_000_000).contains(amount) else { throw invalid }
        case .getSwapMemory(let userID, let groups):
            guard userID == scope.userID, Set(groups).isSubset(of: scope.eligibleSwapGroups) else { throw invalid }
        case .suggestSwaps(let id, let version):
            guard id == scope.budgetID else { throw invalid }
            guard version == scope.preferencesVersion else { throw ToolError(.staleData, "Preferences changed. Refresh the swap proposal.") }
        case .extractReceipt(let id):
            guard scope.attachmentIDs.contains(id) else { throw invalid }
        case .prepareSplit(let id, let assignments, let payer):
            guard scope.receiptIDs.contains(id), scope.contactIDs.contains(payer), !assignments.isEmpty,
                  Set(assignments.keys) == scope.receiptItemIDs,
                  assignments.values.allSatisfy({ !$0.isEmpty && $0.count == Set($0).count && Set($0).isSubset(of: scope.contactIDs) }) else { throw invalid }
        case .commitBudgetPlan, .dispatchRequests:
            throw ToolError(.authRequired, "Approve this action in its review screen. Model output cannot authorize a mutation.")
        }
    }
}
