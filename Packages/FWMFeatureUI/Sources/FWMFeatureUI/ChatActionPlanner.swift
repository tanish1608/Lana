import Foundation
import FinanceAI
import FWMCore

/// One unpaid or reported dinner request, as the Receipts screen shows it.
struct ChatRequestRow: Sendable, Equatable {
    let contactID: String, name: String, amountCents: Int, state: String
}

/// Resolves what the model asked for against a snapshot of the app's real state and returns a confirm card. The model
/// supplies words; this picks exact IDs. No match, or more than one, throws a clarifying question instead of guessing.
struct ChatActionPlanner: ChatActionPlanning {
    let dataset: Dataset
    let requests: [ChatRequestRow]
    let useHistory: Bool

    func plan(_ request: ChatActionRequest, scope: CoreScope) async throws -> ChatAction {
        guard scope.userID == dataset.user.userId else { throw ToolError(.authRequired, "This chat belongs to another user.") }
        var request = request
        if let said = request.utterance, !said.isEmpty {
            // The user's words win: a target the user never said is replaced by the message itself, which `best`
            // and the merchant/category lookups then resolve.
            if let t = request.target, Self.words(t).isDisjoint(with: Self.words(said)) { request.target = said }
            if request.target == nil, request.kind != .adoptPlan { request.target = said }
            if request.kind == .recategorize, let v = request.value, Self.words(v).isDisjoint(with: Self.words(said)) { request.value = said }
        }
        switch request.kind {
        case .keepIdea, .skipIdea: return try idea(request.target, keep: request.kind == .keepIdea)
        case .adoptPlan:
            return ChatAction(kind: "adopt_plan", title: "Adopt your budget plan",
                              detail: "Opens Budget to review the plan; Face ID confirms. Savings are projected. No money moves.",
                              payload: [:], confirmLabel: "Review and adopt", requiresAuthentication: true)
        case .markPaid, .markRequested: return try mark(request.target, paid: request.kind == .markPaid)
        case .recategorize: return try recategorize(request.target, to: request.value, on: request.date)
        case .openScreen: return try open(request.target)
        case .removeAccount: return try remove(request.target)
        }
    }

    // MARK: actions

    private func idea(_ target: String?, keep: Bool) throws -> ChatAction {
        let swaps = useHistory ? PreviewBudgetPlan.swaps : PreviewBudgetPlan.swaps.map { $0.id == "s_coffee" ? PreviewBudgetPlan.instantCoffee : $0 }
        let ideas: [(id: String, title: String, text: String, detail: String, cents: Int)] =
            swaps.map { ($0.id, $0.title, "\($0.title) \($0.category) \($0.from) \($0.to) \($0.group)", "\($0.from) → \($0.to)", $0.savingsCents) }
            + PreviewBudgetPlan.habits.map { ($0.id, $0.title, "\($0.title) \($0.category) \($0.reason)", $0.reason, $0.savingsCents) }
        let i = try best(target, in: ideas, text: \.text, name: \.title, what: "budget idea")
        return ChatAction(kind: keep ? "keep_idea" : "skip_idea", title: keep ? "Keep “\(i.title)” in your plan" : "Skip “\(i.title)”",
                          detail: "\(i.detail) · saves \(usd(i.cents, cents: true))/month.", payload: ["idea_id": i.id, "keep": String(keep)],
                          confirmLabel: keep ? "Keep it" : "Skip it")
    }

    private func mark(_ target: String?, paid: Bool) throws -> ChatAction {
        guard !requests.isEmpty else { throw ToolError(.invalidArguments, "There are no split requests to update. Review the dinner split first.") }
        let r = try best(target, in: requests, text: \.name, name: \.name, what: "person")
        let state = paid ? RequestState.paidReported : RequestState.userReportedRequested
        guard r.state != state.label else { throw ToolError(.invalidArguments, "\(r.name) is already marked \(state.label).") }
        return ChatAction(kind: "mark_request", title: paid ? "Mark \(r.name) as paid (\(usd(r.amountCents, cents: true)))" : "Mark \(r.name)’s request as sent",
                          detail: "Records what you told Lana. It isn’t confirmation from a bank or Venmo.",
                          payload: ["contact_id": r.contactID, "state": state.rawValue], confirmLabel: paid ? "Mark paid" : "Mark sent")
    }

    private func recategorize(_ target: String?, to value: String?, on date: String?) throws -> ChatAction {
        let known = Set(dataset.transactions.compactMap(\.category)).union(["Groceries", "Dining", "Transport", "Bills and subscriptions", "Other", "Rent"])
            .subtracting(["Income", "Transfer"]).sorted()
        // A category named exactly, else the one category whose words appear in the text ("...to groceries").
        let named = value.map { v in known.filter { !Self.words($0).isEmpty && Self.words($0).isSubset(of: Self.words(v)) } } ?? []
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let category = known.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) ?? (named.count == 1 ? named[0] : nil)
                ?? known.first(where: { $0.localizedCaseInsensitiveContains(raw) }) else {
            throw ToolError(.invalidArguments, "Which category? Choose one of: \(known.joined(separator: ", ")).")
        }
        guard let words = target?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { throw ToolError(.invalidArguments, "Which purchase should move?") }
        let day = try LocalLedger.validDate(date)
        let tz = TimeZone(identifier: dataset.user.timezone) ?? .current
        // Merchants whose full name is in the text ("move my target purchase…" names Target), else a substring match.
        let said = Self.words(words)
        let merchants = Set(dataset.transactions.map(\.merchant))
        let mentioned = merchants.filter { !Self.words($0).isEmpty && Self.words($0).isSubset(of: said) }
        guard mentioned.count <= 1 else { throw ToolError(.invalidArguments, "Which store: \(mentioned.sorted().joined(separator: " or "))?") }
        let matches = dataset.transactions.filter { t in
            (mentioned.first.map { t.merchant == $0 } ?? t.merchant.localizedCaseInsensitiveContains(words)) && t.signedAmountCents < 0 && t.transferPairId == nil
                && (day == nil || LocalLedger.localDate(t.postedAt, tz) == day)
        }
        guard !matches.isEmpty else { throw ToolError(.invalidArguments, "No purchases at “\(words)”\(day.map { " on \($0)" } ?? "") were found.") }
        let moving = matches.filter { $0.category != category }
        guard !moving.isEmpty else { throw ToolError(.invalidArguments, "Those purchases are already in \(category).") }
        guard moving.count <= 25 else { throw ToolError(.invalidArguments, "That matches \(moving.count) purchases. Add a date to pick one.") }
        let merchant = moving[0].merchant
        let list = moving.prefix(4).map { "\(LocalLedger.localDate($0.postedAt, tz) ?? String($0.postedAt.prefix(10))) \(usd($0.signedAmountCents, cents: true))" }.joined(separator: ", ")
        return ChatAction(kind: "recategorize", title: moving.count == 1 ? "Move \(merchant) to \(category)" : "Move \(moving.count) \(merchant) purchases to \(category)",
                          detail: "\(list)\(moving.count > 4 ? ", …" : "") · from \(Set(moving.compactMap(\.category)).sorted().joined(separator: ", ")). Totals and budget update.",
                          payload: ["transaction_ids": moving.map(\.transactionId).joined(separator: ","), "category": category], confirmLabel: "Move")
    }

    private func open(_ target: String?) throws -> ChatAction {
        let screens: [(id: String, name: String, text: String)] = [
            ("home", "Home", "home overview"), ("money", "Money", "money spending cash flow net worth"),
            ("budget", "Budget", "budget plan savings swaps ideas"), ("split", "Receipts", "receipts receipt split dinner"),
            ("accounts", "Accounts", "accounts account banks vault keys approvals")]
        let s = try best(target, in: screens, text: \.text, name: \.name, what: "screen")
        return ChatAction(kind: "open_screen", title: "Open \(s.name)", detail: "Closes chat and shows \(s.name).", payload: ["screen": s.id], confirmLabel: "Open")
    }

    private func remove(_ target: String?) throws -> ChatAction {
        let removable = dataset.accounts.filter { AccountDisplay($0).isImported }
        guard !removable.isEmpty else { throw ToolError(.invalidArguments, "Only accounts you imported or linked can be removed, and there are none.") }
        let rows = removable.map { a in (account: a, name: "\(a.institution) \(AccountDisplay(a).subtitle)", text: "\(a.institution) \(AccountKind.name(a.kind)) \(AccountDisplay(a).title)") }
        let r = try best(target, in: rows, text: \.text, name: \.name, what: "imported account")
        return ChatAction(kind: "remove_account", title: "Remove \(r.name)",
                          detail: "Its transactions leave Lana on this iPhone. Nothing changes at \(r.account.institution).",
                          payload: ["account_id": r.account.accountId], confirmLabel: "Remove")
    }

    // MARK: matching

    /// The single candidate sharing the most words with `target`. Ties or no overlap ask the user to choose.
    private func best<T>(_ target: String?, in items: [T], text: KeyPath<T, String>, name: KeyPath<T, String>, what: String) throws -> T {
        let options = items.map { $0[keyPath: name] }.joined(separator: ", ")
        let want = Self.words(target ?? "")
        guard !want.isEmpty else { throw ToolError(.invalidArguments, "Which \(what)? Options: \(options).") }
        let scored = items.map { (item: $0, score: want.intersection(Self.words($0[keyPath: text])).count) }.filter { $0.score > 0 }
        guard let top = scored.map(\.score).max() else { throw ToolError(.invalidArguments, "I couldn’t find that \(what). Options: \(options).") }
        let winners = scored.filter { $0.score == top }
        guard winners.count == 1 else { throw ToolError(.invalidArguments, "Which \(what) did you mean: \(winners.map { $0.item[keyPath: name] }.joined(separator: " or "))?") }
        return winners[0].item
    }

    static func words(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "my", "a", "an", "to", "in", "of", "for", "and", "on", "as", "it", "is", "plan", "swap", "idea", "screen", "tab", "account"]
        return Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .map { $0.hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : $0 }.filter { $0.count > 1 && !stop.contains($0) })
    }
}
