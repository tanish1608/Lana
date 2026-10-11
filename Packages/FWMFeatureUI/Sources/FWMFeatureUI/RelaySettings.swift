import SwiftUI
import Observation
import FinanceAI
import FWMCore

@Observable @MainActor
final class LanaRelayConnection {
    private struct Stored: Codable { let url: URL; let pairing: RelayPairing }
    var status = "Not paired. Messaging relay is optional."
    var connected = false
    var busy = false
    var foreground = true
    private var worker: RelayWorker?
    private let chat: LanaChatController
    private var dataset: Dataset { chat.dataset }
    init(chat: LanaChatController) { self.chat = chat }
    private var key: VaultKey { VaultKey(userID: dataset.user.userId, name: "relay-pairing-v1") }
    private func vault() throws -> KeychainVault { try KeychainVault(service: "io.speedhacks.LanaDemoApp") }
    func pair(address: String, code: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { throw VaultFailure("Enter the relay's HTTPS base URL.") }
            let pairing = try await RelayClient.pair(baseURL: url, code: code, pairedUserId: dataset.user.userId)
            guard pairing.pairedUserId == dataset.user.userId else { throw VaultFailure("This relay is paired to a different user.") }
            let saved = Stored(url: url, pairing: pairing)
            try await vault().store(JSONEncoder().encode(saved), for: key)
            await connect(saved)
        } catch { status = error.localizedDescription }
    }
    func restore() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let data = try await vault().read(key, reason: "Reconnect Lana to your paired messaging relay")
            let saved = try JSONDecoder().decode(Stored.self, from: data)
            guard saved.pairing.pairedUserId == dataset.user.userId else { throw VaultFailure("Stored pairing belongs to another user.") }
            await connect(saved)
        } catch { status = error.localizedDescription }
    }
    private func connect(_ saved: Stored) async {
        await worker?.stop()
        let client = RelayClient(baseURL: saved.url, deviceToken: saved.pairing.deviceToken)
        let chat = self.chat
        worker = RelayWorker(client: client, tools: ForegroundFeatureTools(chat: chat), contextFor: { job in
            await MainActor.run {
                let s = chat.scope
                let scope = CoreScope(userID: s.userID, conversationID: job.envelope.conversationId, period: s.period,
                    datasetVersion: s.datasetVersion, preferencesVersion: s.preferencesVersion, accountIDs: s.accountIDs,
                    receiptIDs: s.receiptIDs, contactIDs: s.contactIDs, receiptItemIDs: s.receiptItemIDs,
                    budgetID: s.budgetID, eligibleSwapGroups: s.eligibleSwapGroups)
                return CoreRoutingContext(scope: scope, reviewedSplit: chat.reviewedSplit)
            }
        }, onAnswered: { job, result in await chat.recordRelay(job, result) })
        connected = true
        await setForeground(foreground)
    }
    func setForeground(_ value: Bool) async {
        foreground = value
        guard let worker else { return }
        if value { await worker.start(); status = "Paired. Listening while Lana is open; network errors retry automatically." }
        else { await worker.stop(); status = "Paired. Open Lana to process messaging jobs." }
    }
    func disconnect() async {
        await worker?.stop(); worker = nil; connected = false
        status = "Disconnected on this device. Saved pairing can be reconnected."
    }
    func forget() async {
        await disconnect()
        do { try await vault().remove(key); status = "Pairing removed from this device." }
        catch { status = error.localizedDescription }
    }
}

struct RelaySettings: View {
    @Bindable var connection: LanaRelayConnection
    @State private var address = ""
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Messaging relay") {
                    Text(connection.status).font(.footnote)
                    Text("Pair with your team's relay. AI runs locally; authenticated jobs are processed while this app is in the foreground. Pairing credentials stay in device-bound Keychain storage.").font(.footnote)
                    TextField("https://your-relay-host", text: $address)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        #endif
                    SecureField("Pairing code", text: $code)
                    Button("Pair this iPhone") { Task { await connection.pair(address: address, code: code); code = "" } }
                        .disabled(connection.busy || address.isEmpty || code.isEmpty)
                    Button("Reconnect saved pairing") { Task { await connection.restore() } }.disabled(connection.busy)
                    if connection.connected { Button("Disconnect") { Task { await connection.disconnect() } } }
                    Button("Forget saved pairing", role: .destructive) { Task { await connection.forget() } }.disabled(connection.busy)
                }
                Section("Version 1") {
                    Text("In-app chat supports natural language and PDF context. Relay jobs use the scoped task router; attachments and receipt assignments require in-app review. Venmo handoffs and split reminders are labelled demo actions in the feature screens.").font(.footnote)
                }
            }.navigationTitle("Messaging").toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Read the current UI selection for each relay job. A concurrent revision is rejected by scope validation.
struct ForegroundFeatureTools: CoreToolExecuting {
    let chat: LanaChatController
    func query(_ call: ToolCall, scope: CoreScope) async throws -> CoreToolOutput {
        let tools = await MainActor.run { chat.tools }
        return try await tools.query(call, scope: scope)
    }
}
