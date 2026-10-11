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
    /// On-device SQLite ledger: mirrors the session dataset for the agent's `ledger` tool, keeps imported accounts
    /// across relaunches, and journals app activity. Nil only if the database can't be opened.
    let ledger: LocalLedger?
    private var ledgerWrites: Task<Void, Never>?
    var messages: [ConversationMessage] { archive?.messages ?? [] }
    init(dataset: Dataset, directory: URL = URL.applicationSupportDirectory.appendingPathComponent("FinanceChats", isDirectory: true)) {
        self.dataset = dataset
        store = ConversationStore(directory: directory)
        ledger = try? LocalLedger(directory: directory.appendingPathComponent("ledger", isDirectory: true))
        archive = ConversationArchive(userID: dataset.user.userId, datasetVersion: dataset.datasetVersion)
    }
    /// Ledger writes run one after another, so a later dataset can't be overwritten by an earlier one.
    private func ledgerWrite(_ work: @escaping @Sendable (LocalLedger) async throws -> Void) {
        guard let ledger else { return }
        let previous = ledgerWrites
        ledgerWrites = Task { await previous?.value; try? await work(ledger) }
    }
    /// Waits for pending ledger writes, e.g. before the agent reads it.
    func ledgerSettled() async { await ledgerWrites?.value }
    private func mirrorDataset() { let snapshot = dataset; ledgerWrite { try await $0.sync(snapshot) } }
    /// Records something the user did, for the agent's activity answers and the Approvals list after relaunch.
    func journal(_ kind: String, _ summary: String, details: [String: String] = [:]) {
        let user = dataset.user.userId, event = LedgerEvent(kind: kind, summary: summary, details: details)
        ledgerWrite { try await $0.record(event, userID: user) }
    }
    /// Journal kinds shown in Accounts › Approvals.
    static let approvalKinds: Set<String> = ["plan_adopted", "plan_item_confirmed", "split_reviewed", "split_action", "account_imported", "account_removed"]
    func approvalLog() async -> [String] {
        await ledgerSettled()
        return (try? await ledger?.events(userID: dataset.user.userId, kinds: Self.approvalKinds, limit: 50).map(\.summary)) ?? []
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
        mirrorDataset()
    }
    /// Removes an imported account and its transactions. Fixture accounts stay.
    func removeImportedAccount(_ id: String) {
        guard dataset.accounts.contains(where: { $0.accountId == id && $0.sourceId?.hasPrefix("csv:") == true }) else { return }
        dataset.accounts.removeAll { $0.accountId == id }
        dataset.transactions.removeAll { $0.accountId == id }
        invalidateEvidence()
        mirrorDataset()
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
        // Statement accounts imported in an earlier session come back before anything reads the dataset.
        if let ledger, let saved = try? await ledger.importedAccounts(userID: dataset.user.userId) {
            for (account, txns) in saved where !dataset.accounts.contains(where: { $0.accountId == account.accountId }) {
                dataset.accounts.append(account)
                dataset.transactions += txns
            }
            if !saved.isEmpty { invalidateEvidence() }
        }
        mirrorDataset()
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
        await ledgerSettled()
        let assistant = ConversationalAssistant(context: CoreRoutingContext(scope: scope, reviewedSplit: reviewedSplit), tools: tools, ledger: ledger)
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
    private func persist() async {
        guard var current = archive else { return }
        current.updatedAt = Date(); archive = current
        do {
            try await store.save(current)
            savedChats = try await store.load(userID: current.userID)
        } catch { status = "Chat is available in this session but couldn't be saved: \(error.localizedDescription)" }
    }
}
