import Foundation

/// Deliberately conservative offline fallback. Unsupported or multi-intent input asks
/// for clarification; it never silently delegates to a server.
public struct RuleRouter: IntentRouting {
    public init() {}
    public func route(_ text: String) async throws -> RoutedRequest {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 2_000 else { throw FinanceAIError.invalidInput }
        let lower = clean.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if words.contains("cancel") {
            // Negation, multiple targets and ambiguous actions must not become proposals.
            if words.intersection(["not", "dont", "don", "never", "and", "all"]).isEmpty {
                let range = lower.range(of: "cancel")!
                let target = String(clean[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty {
                    return RoutedRequest(request: .init(intent: .proposeCancellation, target: target), source: .deterministicFallback)
                }
            }
            return RoutedRequest(request: .init(intent: .unknown), source: .deterministicFallback)
        }
        var intents: Set<FinanceIntent> = []
        if lower.contains("net worth") || lower == "how am i doing?" || lower == "how am i doing" { intents.insert(.netWorth) }
        if !words.intersection(["spending", "spend"]).isEmpty || lower.contains("money going") { intents.insert(.spending) }
        if words.contains("budget") { intents.insert(.budget) }
        if !words.intersection(["forecast", "overdraft", "shortfall", "payday"]).isEmpty || lower.contains("run out") { intents.insert(.forecast) }
        if !words.intersection(["subscriptions", "subscription", "savings"]).isEmpty { intents.insert(.subscriptions) }
        if !words.intersection(["grocery", "groceries", "shopping"]).isEmpty { intents.insert(.groceries) }
        if !words.intersection(["bill", "bills"]).isEmpty { intents.insert(.bills) }
        return RoutedRequest(request: .init(intent: intents.count == 1 ? intents.first! : .unknown), source: .deterministicFallback)
    }
}
