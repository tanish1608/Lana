import Foundation
import FinanceAI
import FWMCore

enum DemoEnvironment {
    static func agent() throws -> (CoreAgent, CoreScope) {
        guard let url = Bundle.main.url(forResource: "seed-v1", withExtension: "json") else {
            throw ToolError(.invalidArguments, "Canonical seed-v1 fixture is missing from the app bundle.")
        }
        let ds = try Dataset.load(from: url)
        let scope = CoreScope(userID: ds.user.userId, conversationID: "app-fixture-conversation",
            period: "2026-09", datasetVersion: ds.datasetVersion, preferencesVersion: ds.user.preferencesVersion,
            accountIDs: Set(ds.accounts.map(\.accountId)), receiptIDs: Set((ds.receipts ?? []).map(\.receiptId)),
            contactIDs: Set((ds.contacts ?? []).map(\.contactId)),
            receiptItemIDs: Set(ds.receipts?.first?.items.map(\.itemId) ?? []))
        // Reviewed fixture assignments only; AI never invents contact IDs or who ate what.
        let split = ReviewedSplit(receiptID: "rcpt_dinner_1011", payerID: "c_ashwin", assignments:
            ["it_1": ["c_tanish"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin", "c_tanish", "c_aryan"]])
        let context = CoreRoutingContext(scope: scope, reviewedSplit: split)
        return (CoreAgent(context: context, tools: CoreDatasetTools(dataset: ds)), scope)
    }
    static func message(_ text: String, scope: CoreScope) throws -> MessageEnvelope {
        let data = try JSONSerialization.data(withJSONObject: [
            "event_id": UUID().uuidString, "conversation_id": scope.conversationID,
            "paired_user_id": scope.userID, "channel": "app", "received_at": ISO8601DateFormatter().string(from: Date()),
            "text": text, "attachments": []
        ])
        return try FWMJSON.decoder.decode(MessageEnvelope.self, from: data)
    }
}
