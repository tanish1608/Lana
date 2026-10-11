import Foundation
import FinanceAI

/// Integration-only fixture. Teammates replace this adapter with their data/engines.
actor DemoTools: FinanceToolProviding {
    private var active = true
    private var completed: [UUID: FinanceResult] = [:]
    private let checking = 56_000
    private let rent = 55_000
    private let subscription = 2_500

    func query(_ request: FinanceRequest, context: UserContext) async throws -> FinanceResult {
        guard context.userID == "demo-alex" else { throw FinanceAIError.invalidConfiguration }
        switch request.intent {
        case .netWorth:
            return .init(summary: "Fixture net worth: \(money(checking + 150_000 - 40_000)). Checking, savings, and credit card debt included.", evidence: ["Demo fixture only"])
        case .forecast:
            return forecast()
        case .subscriptions:
            return .init(summary: active ? "StreamPlus: $25/month. Usage is simulated; no use recorded for 60 days. Ask ‘Cancel StreamPlus’ to prepare an action." : "StreamPlus is cancelled in this demo. Future recurring charge removed.", evidence: ["Fixture recurring record", "Simulated usage record"])
        case .proposeCancellation:
            guard let target = request.target, target.lowercased().trimmingCharacters(in: .punctuationCharacters) == "streamplus" else {
                return .init(summary: "Name the fixture subscription exactly: StreamPlus.")
            }
            guard active else { return .init(summary: "StreamPlus is already cancelled in this demo.") }
            return .init(summary: "Cancel the simulated StreamPlus subscription at $25/month? This removes the next fixture charge. No real merchant is contacted.",
                proposedAction: .init(kind: .cancelSubscription, targetID: "streamplus-1",
                    confirmationSummary: "Cancel simulated StreamPlus at $25/month", expectedVersion: "v1"))
        case .spending:
            return .init(summary: "Fixture spending: groceries $240, transport $80, subscriptions $25. Total: $345.", evidence: ["Precomputed fixture categories"])
        case .budget:
            return .init(summary: "The budget adapter belongs to the UI/engine lane. This lab verifies routing only.")
        case .groceries:
            return .init(summary: "The grocery adapter belongs to the UI/engine lane. Import a receipt in the Receipt tab to inspect local extraction.")
        case .bills:
            return .init(summary: "Upcoming fixture rent: $550. StreamPlus: \(active ? "$25" : "cancelled"). Both occur before the next payday.")
        case .unknown:
            return .init(summary: "Try asking about your forecast or subscriptions.")
        }
    }
    func execute(_ action: ConfirmedAction) async throws -> FinanceResult {
        guard action.context.userID == "demo-alex" else { throw FinanceAIError.invalidConfiguration }
        if let result = completed[action.id] { return result }
        guard action.proposal.kind == .cancelSubscription, action.proposal.targetID == "streamplus-1",
              action.proposal.expectedVersion == "v1", active else { throw FinanceAIError.invalidConfiguration }
        active = false
        let result = FinanceResult(summary: "Simulated cancellation complete. \(forecast().summary)", evidence: ["Action \(action.id)", "Fresh forecast calculated from fixture state"])
        completed[action.id] = result
        return result
    }
    private func forecast() -> FinanceResult {
        let low = checking - rent - (active ? subscription : 0)
        return .init(summary: "Projected minimum checking balance before payday: \(money(low)). \(low < 0 ? "A shortfall is projected." : "The fixture bills are covered.")", evidence: ["Checking $560", "Upcoming rent $550", active ? "Upcoming StreamPlus $25" : "StreamPlus charge removed"])
    }
    private func money(_ cents: Int) -> String {
        let magnitude = abs(cents)
        return "\(cents < 0 ? "-" : "")$\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }
}

#if targetEnvironment(simulator)
/// Only exists in simulator builds; never bypasses device auth on a physical phone.
struct SimulatorAuthentication: ActionAuthenticating {
    func authenticate(reason: String) async throws {}
}
#endif
