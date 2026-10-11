import SwiftUI
import UniformTypeIdentifiers
import Observation
import FinanceAI
import FWMCore

@Observable @MainActor
final class LanaChatController {
    var archive: ConversationArchive?
    var savedChats: [ConversationArchive] = []
    var busy = false
    var status: String?
    var dataset: Dataset
    var reviewedSplit: ReviewedSplit?
    var requestStates: [String: String] = [:]
    var accepted = Set(PreviewBudgetPlan.swaps.map(\.id) + PreviewBudgetPlan.habits.map(\.id))
    var useHistory = true
    var budgetAdopted = false
    var scope: CoreScope {
        CoreScope(userID: dataset.user.userId, conversationID: archive?.id.uuidString ?? "app",
            period: "2026-09", datasetVersion: dataset.datasetVersion, preferencesVersion: dataset.user.preferencesVersion,
            accountIDs: Set(dataset.accounts.map(\.accountId)), receiptIDs: Set((dataset.receipts ?? []).map(\.receiptId)),
            contactIDs: Set((dataset.contacts ?? []).map(\.contactId)), receiptItemIDs: Set((dataset.receipts ?? []).flatMap { $0.items.map(\.itemId) }),
            budgetID: "demo-budget", eligibleSwapGroups: Set(PreviewBudgetPlan.swaps.map(\.group)))
    }
    var tools: FeatureTools { FeatureTools(dataset: dataset, requestStates: requestStates, accepted: accepted, useHistory: useHistory, budgetAdopted: budgetAdopted) }
    private var restored = false
    private let store: ConversationStore
    var messages: [ConversationMessage] { archive?.messages ?? [] }
    init(dataset: Dataset, directory: URL = URL.applicationSupportDirectory.appendingPathComponent("FinanceChats", isDirectory: true)) {
        self.dataset = dataset
        store = ConversationStore(directory: directory)
        archive = ConversationArchive(userID: dataset.user.userId, datasetVersion: dataset.datasetVersion)
    }
    func updateBudget(accepted: Set<String>, useHistory: Bool) {
        self.accepted = accepted; self.useHistory = useHistory; budgetAdopted = false
        invalidateEvidence()
    }
    /// Adds an account imported on this phone; earlier financial evidence no longer describes the dataset.
    func addAccount(_ account: Account, transactions: [FWMCore.Transaction]) {
        guard !dataset.accounts.contains(where: { $0.accountId == account.accountId }) else { return }
        dataset.accounts.append(account)
        dataset.transactions += transactions.filter { $0.accountId == account.accountId }
        invalidateEvidence()
    }
    /// Removes an imported account and its transactions. Fixture accounts stay.
    func removeImportedAccount(_ id: String) {
        guard dataset.accounts.contains(where: { $0.accountId == id && $0.sourceId?.hasPrefix("csv:") == true }) else { return }
        dataset.accounts.removeAll { $0.accountId == id }
        dataset.transactions.removeAll { $0.accountId == id }
        invalidateEvidence()
    }
    private func invalidateEvidence() {
        dataset.datasetVersion = "session-" + UUID().uuidString
        archive?.datasetVersion = dataset.datasetVersion
    }
    func review(receipt: Receipt, assignments: [String: [String]], payerID: String) {
        dataset.receipts = [receipt]
        // Invalidate earlier receipt evidence when the reviewed input changes.
        invalidateEvidence()
        reviewedSplit = ReviewedSplit(receiptID: receipt.receiptId, payerID: payerID, assignments: assignments)
        archive?.datasetVersion = dataset.datasetVersion
    }
    func restore() async {
        guard !restored else { return }
        restored = true; busy = true
        defer { busy = false }
        do {
            savedChats = try await store.load(userID: scope.userID)
            if let latest = savedChats.first { archive = latest }
        } catch { status = "Couldn't restore saved chats: \(error.localizedDescription)" }
    }
    func newChat() async {
        guard !busy else { return }
        archive = ConversationArchive(userID: scope.userID, datasetVersion: scope.datasetVersion)
        status = nil
        await persist()
    }
    func select(_ chat: ConversationArchive) {
        guard !busy else { return }
        archive = chat; status = nil
    }
    func send(_ text: String) async {
        guard !busy, var current = archive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; status = nil
        defer { busy = false }
        current.datasetVersion = dataset.datasetVersion
        let context = current
        let assistant = ConversationalAssistant(context: CoreRoutingContext(scope: scope, reviewedSplit: reviewedSplit), tools: tools)
        current.messages.append(.init(role: .user, text: text)); archive = current
        await persist()
        do {
            let response = try await assistant.respond(to: text, archive: context)
            archive?.messages.append(.init(role: .assistant, text: response.text,
                source: response.source.rawValue, evidence: response.evidence))
            status = dataset.datasetVersion == context.datasetVersion ? response.notice
                : "The screen selection changed while this reply was generated. Its evidence reflects the earlier selection; ask again for current figures."
        } catch {
            archive?.messages.append(.init(role: .assistant,
                text: (error as? ToolError)?.userMessage ?? error.localizedDescription))
        }
        await persist()
    }
    func importPDF(_ url: URL) async {
        guard !busy else { return }
        busy = true; status = "Reading PDF on this device…"
        defer { busy = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard byteCount <= 50_000_000 else { throw FinanceAIError.unavailable("Choose a PDF smaller than 50 MB.") }
            let document = try await PDFTextImporter().extract(data: Data(contentsOf: url), name: url.lastPathComponent)
            archive?.documents.append(document)
            archive?.messages.append(.init(role: .assistant,
                text: "I've added \(document.name) (\(document.pages.count) pages). What would you like to know about it?"))
            status = document.notice
            await persist()
        } catch { status = error.localizedDescription }
    }
    func removeDocument(_ id: UUID) async {
        guard !busy else { return }
        archive?.documents.removeAll { $0.id == id }
        await persist()
    }
    /// A text or call answered through the relay, kept like an in-app chat: same archive format, same store, shown in History.
    func recordRelay(_ job: RelayJob, _ result: AgentResult) async {
        let envelope = job.envelope
        do {
            let fresh = ConversationArchive(relayConversation: envelope.conversationId, userID: dataset.user.userId, datasetVersion: dataset.datasetVersion)
            var thread = try await store.load(userID: fresh.userID).first { $0.id == fresh.id } ?? fresh
            let call = thread.channel == "Call"
            thread.messages.append(.init(role: .user, text: envelope.text ?? "Photo", source: call ? "Phone call, transcribed by Dial" : "Text message"))
            thread.messages.append(.init(role: .assistant, text: result.replyText, source: call ? "Spoken by Dial, answered on this device" : "Texted back, answered on this device",
                evidence: result.provenance.map { [ChatEvidence(text: result.replyText, provenance: $0)] } ?? []))
            thread.datasetVersion = dataset.datasetVersion
            thread.updatedAt = Date()
            try await store.save(thread)
            savedChats = try await store.load(userID: thread.userID)
            if archive?.id == thread.id { archive = thread }
        } catch { status = "A relay conversation couldn't be saved: \(error.localizedDescription)" }
    }
    private func persist() async {
        guard var current = archive else { return }
        current.updatedAt = Date(); archive = current
        do {
            try await store.save(current)
            savedChats = try await store.load(userID: current.userID)
        } catch { status = "Chat is available in this session but couldn't be saved: \(error.localizedDescription)" }
    }
}
