import Foundation
import FinanceAI
import FWMCore

/// The UI's demo catalog and the chat adapter share one deterministic projection.
struct BudgetProjection {
    let current: MoneyView
    let targets: [String: Int]
    let savingsCents: Int
    static func make(dataset: Dataset, period: String, accepted: Set<String>, useHistory: Bool) throws -> Self {
        let current = try MoneyEngine.moneyView(dataset, period: period)
        var targets = Dictionary(uniqueKeysWithValues: current.categories.map { ($0.category, $0.totalCents) })
        let swaps = useHistory ? PreviewBudgetPlan.swaps : PreviewBudgetPlan.swaps.map { $0.id == "s_coffee" ? PreviewBudgetPlan.instantCoffee : $0 }
        for s in swaps where accepted.contains(s.id) { targets[s.category, default: 0] -= s.savingsCents }
        for h in PreviewBudgetPlan.habits where accepted.contains(h.id) { targets[h.category, default: 0] -= h.savingsCents }
        guard targets.values.allSatisfy({ $0 >= 0 }) else { throw ToolError(.invalidArguments, "This month's spending cannot support the demo catalog reductions.") }
        return Self(current: current, targets: targets, savingsCents: current.flow.expensesCents - targets.values.reduce(0, +))
    }
}

struct FeatureTools: CoreToolExecuting {
    let dataset: Dataset
    var requestStates: [String: String] = [:]
    var accepted = Set(PreviewBudgetPlan.swaps.map(\.id) + PreviewBudgetPlan.habits.map(\.id))
    var useHistory = true
    var budgetAdopted = false
    func query(_ call: ToolCall, scope: CoreScope) async throws -> CoreToolOutput {
        guard dataset.user.userId == scope.userID, dataset.datasetVersion == scope.datasetVersion else {
            throw ToolError(.authRequired, "This data does not belong to the current session.")
        }
        try CoreToolValidator.validateRead(call, scope: scope)
        switch call {
        case .getMoneyView(let period, let filter):
            let base = try await CoreDatasetTools(dataset: dataset).query(call, scope: scope)
            let v = try MoneyEngine.moneyView(dataset, period: period, accountFilter: filter)
            let categories = v.categories.map { "\($0.category): \(CoreDatasetTools.money($0.totalCents))" }.joined(separator: "; ")
            let accounts = v.accounts.map { "\($0.institution) \($0.kind): \(CoreDatasetTools.money($0.balanceCents))" }.joined(separator: "; ")
            let status = requestStates.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            return .init(replyText: base.replyText + " Categories: " + categories + ". Accounts: " + accounts
                + ". Budget adopted in this session: \(budgetAdopted). User-reported dinner request states: \(status.isEmpty ? "none; requests not sent" : status).",
                provenance: base.provenance, cardID: base.cardID)
        case .prepareSplit(let id, let assignments, let payer):
            let base = try await CoreDatasetTools(dataset: dataset).query(call, scope: scope)
            guard let receipt = dataset.receipts?.first(where: { $0.receiptId == id }) else { throw ToolError(.invalidArguments, "Reviewed receipt missing.") }
            let split = try SplitEngine.prepareSplit(receipt: receipt, assignments: assignments, payerId: payer,
                contacts: dataset.contacts ?? [], datasetVersion: dataset.datasetVersion, dataMode: receipt.receiptId.hasPrefix("local-") ? .cached : dataset.dataMode)
            let pending = split.requests.filter { !["Paid (you said)", "Cancelled"].contains(requestStates[$0.reviewedName] ?? "Draft") }
            let roster = pending.map { "\($0.reviewedName): \(CoreDatasetTools.money($0.amountCents))" }.joined(separator: "; ")
            let outstanding = pending.reduce(0) { $0 + $1.amountCents }
            return .init(replyText: base.replyText.replacingOccurrences(of: "No requests sent.", with: "Lana has sent no requests.").replacingOccurrences(of: "Data mode: fixture.", with: "Data mode: \(split.provenance.dataMode.rawValue).") + " After user-reported paid/cancelled states, unpaid draft reimbursements are \(CoreDatasetTools.money(outstanding)): \(roster.isEmpty ? "none" : roster). These are user reports, not verified bank settlement.", provenance: split.provenance, cardID: split.provenance.resultId)
        case .proposeBudget(let period, let goal):
            return try budget(period: period, goal: goal)
        case .suggestSwaps:
            return try budget(period: scope.period, goal: PreviewBudgetPlan.goalCents)
        case .getSwapMemory:
            return .init(replyText: useHistory ? "Demo preference history excludes instant coffee; preserve preferred oat milk and rent. This is fixture memory, not a live provider result." : "Preference history disabled in the current Budget screen. Brand locks still apply.",
                provenance: Provenance(resultId: "memory:\(dataset.datasetVersion):\(useHistory)", datasetVersion: dataset.datasetVersion,
                    dataMode: dataset.dataMode, asOf: dataset.asOf, sourceIds: [], evidenceIds: ["demo-coffee-preference"], engineVersion: "feature-demo-v1"))
        default: return try await CoreDatasetTools(dataset: dataset).query(call, scope: scope)
        }
    }
    private func budget(period: String, goal: Int) throws -> CoreToolOutput {
        let p = try BudgetProjection.make(dataset: dataset, period: period, accepted: accepted, useHistory: useHistory)
        let options = (useHistory ? PreviewBudgetPlan.swaps : PreviewBudgetPlan.swaps.map { $0.id == "s_coffee" ? PreviewBudgetPlan.instantCoffee : $0 })
            .filter { accepted.contains($0.id) }.map { "\($0.title): \($0.to), saves \(CoreDatasetTools.money($0.savingsCents))/month. Reason: \($0.reason)" }.joined(separator: "; ")
        let targets = p.targets.sorted { $0.key < $1.key }.map { "\($0.key): \(CoreDatasetTools.money($0.value))" }.joined(separator: "; ")
        let signature = accepted.sorted().joined(separator: ",") + ":\(useHistory)"
        let provenance = Provenance(resultId: "budget:\(dataset.datasetVersion):\(period):\(signature)", datasetVersion: dataset.datasetVersion,
            dataMode: dataset.dataMode, asOf: dataset.asOf, sourceIds: p.current.provenance.sourceIds,
            evidenceIds: accepted.sorted(), engineVersion: "feature-demo-v1")
        return .init(replyText: "Demo catalog projection from \(period), matching the selected Budget options: saves \(CoreDatasetTools.money(p.savingsCents))/month against a requested goal of \(CoreDatasetTools.money(goal)); \(p.savingsCents >= goal ? "goal met" : "goal not met"). \(options). Category targets: \(targets). Rent and savings/investment transfers unchanged. No money moved, purchase made or phone plan switched. Review the Budget screen to adopt this demo plan.", provenance: provenance, cardID: provenance.resultId)
    }
}

/// Real device authentication; no provider MFA challenge is invented for fixture credentials.
public struct NativeVaultUnlocker: VaultUnlocking {
    public init() {}
    public var isSimulated: Bool { false }
    public var requiresSecondFactor: Bool { false }
    public func authenticateDeviceOwner(reason: String) async throws { try await DeviceOwnerAuthenticator().authenticate(reason: reason) }
    public func verifySecondFactor(code: String) async throws { throw VaultFailure("Provider MFA is not configured for demo credentials.") }
}
