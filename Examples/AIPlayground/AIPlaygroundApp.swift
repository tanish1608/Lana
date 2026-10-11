import SwiftUI
import PhotosUI
import Observation
import FinanceAI

@main
struct AIPlaygroundApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ChatLab().tabItem { Label("Agent", systemImage: "bubble.left.and.bubble.right") }
                ReceiptLab().tabItem { Label("Receipt", systemImage: "doc.text.viewfinder") }
                VoiceLab().tabItem { Label("Voice", systemImage: "waveform") }
                VaultLab().tabItem { Label("Vault", systemImage: "lock.shield") }
            }
            .tint(.teal)
        }
    }
}

private struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    var source: String?
}

@Observable @MainActor
private final class ChatController {
    var messages: [ChatMessage] = [.init(text: "Ask about your forecast, find subscriptions, then cancel StreamPlus to see the model change. All financial data and actions in this lab are simulated.", isUser: false)]
    var pending: PendingConfirmation?
    var busy = false
    var audit: [ActionAuditEntry] = []
    private let agent: FinanceAgent
    init() {
        #if targetEnvironment(simulator)
        let authenticator: any ActionAuthenticating = SimulatorAuthentication()
        #else
        let authenticator: any ActionAuthenticating = DeviceOwnerAuthenticator()
        #endif
        agent = FinanceAgent(context: .init(userID: "demo-alex"), router: OnDeviceRouter(),
                             tools: DemoTools(), authenticator: authenticator)
    }
    func send(_ text: String) async {
        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        defer { busy = false }
        messages.append(.init(text: text, isUser: true))
        do {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES", let pending {
                let result = try await agent.confirm(actionID: pending.id, userText: text)
                self.pending = nil
                messages.append(.init(text: result.summary, isUser: false, source: "Confirmed fixture action"))
            } else {
                let result = try await agent.receive(text)
                if let confirmation = result.confirmation { pending = confirmation }
                messages.append(.init(text: result.text, isUser: false,
                                      source: [result.source.rawValue, result.notice].compactMap { $0 }.joined(separator: " · ")))
            }
        } catch {
            messages.append(.init(text: error.localizedDescription, isUser: false))
        }
        audit = await agent.auditLog()
    }
    func decline() async {
        guard let pending, !busy else { return }
        do {
            try await agent.decline(actionID: pending.id)
            self.pending = nil
            messages.append(.init(text: "Action declined. No state changed.", isUser: false))
            audit = await agent.auditLog()
        } catch { messages.append(.init(text: error.localizedDescription, isUser: false)) }
    }
}

private struct ChatLab: View {
    @State private var controller = ChatController()
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(OnDeviceRouter.status.description, systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                    #if targetEnvironment(simulator)
                    Text("Simulator: device authentication is simulated.").font(.caption2).foregroundStyle(.orange)
                    #endif
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(controller.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.isUser ? "YOU" : "FINANCE AI").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(message.text).textSelection(.enabled)
                                    if let source = message.source { Text(source).font(.caption2).foregroundStyle(.secondary) }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.isUser ? Color.teal.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                                .id(message.id)
                            }
                            if controller.busy { ProgressView("Processing on device…") }
                        }.padding()
                    }
                    .onChange(of: controller.messages.count) {
                        if let id = controller.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
                if let pending = controller.pending {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pending.proposal.confirmationSummary).font(.subheadline.weight(.semibold))
                        Text("Approval expires in five minutes. No real service is contacted.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("YES, confirm") { Task { await controller.send("YES") } }.buttonStyle(.borderedProminent)
                            Button("Decline") { Task { await controller.decline() } }.buttonStyle(.bordered)
                        }.disabled(controller.busy)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.08))
                }
                HStack {
                    TextField("Ask about your finances", text: $text, axis: .vertical).lineLimit(1...4)
                        .textFieldStyle(.roundedBorder).onSubmit { submit() }
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .accessibilityLabel("Send request").disabled(controller.busy || text.isEmpty)
                }.padding()
            }
            .navigationTitle("Finance AI Lab")
            .toolbar {
                Menu("Try") {
                    ForEach(["Will I run out before payday?", "Find subscriptions", "Cancel StreamPlus", "Make my grocery list"], id: \.self) { sample in
                        Button(sample) { text = sample }
                    }
                }
                Menu {
                    if controller.audit.isEmpty { Text("No actions yet") }
                    ForEach(controller.audit) { entry in Text("\(entry.proposal.targetID): \(entry.status.rawValue)") }
                } label: { Image(systemName: "list.bullet.clipboard") }
                .accessibilityLabel("Action log")
            }
        }
    }
    private func submit() {
        let request = text
        text = ""
        Task { await controller.send(request) }
    }
}

private struct ReceiptLab: View {
    @State private var selection: PhotosPickerItem?
    @State private var draft: ReceiptDraft?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Receipt images stay on this device. Vision reads the text; the local model proposes structured fields for review.")
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("Choose a receipt", systemImage: "photo")
                    }.disabled(busy)
                    if busy { ProgressView("Reading receipt…") }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                if let draft {
                    Section("Review required") {
                        Text(draft.notice).font(.caption)
                        LabeledContent("Merchant", value: draft.merchant ?? "Not extracted")
                        LabeledContent("Total", value: draft.totalText ?? "Not extracted")
                        ForEach(Array(draft.items.enumerated()), id: \.offset) { _, item in
                            LabeledContent(item.name, value: item.amountText ?? "Check receipt")
                        }
                    }
                    Section("Original OCR") { Text(draft.document.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
            }
            .navigationTitle("Receipt extraction")
            .task(id: selection) {
                guard let selection else { return }
                busy = true
                error = nil
                defer { busy = false }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw FinanceAIError.invalidReceipt }
                    let document = try await ReceiptOCR().recognize(imageData: data)
                    let result = try await ReceiptDraftBuilder().build(from: document)
                    try Task.checkCancellation()
                    draft = result
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct VoiceLab: View {
    @State private var recorder = VoiceRecorder()
    @State private var transcriber = OnDeviceSpeechTranscriber()
    @State private var recording = false
    @State private var busy = false
    @State private var transcript = ""
    @State private var notice = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Record a financial question, then review the local transcript before sending it to the agent. Audio files are deleted after transcription.")
                    Button(recording ? "Stop and transcribe" : "Record request", systemImage: recording ? "stop.circle" : "mic") {
                        Task { await toggle() }
                    }.disabled(busy)
                    if busy { ProgressView("Transcribing locally…") }
                    if !notice.isEmpty { Text(notice).font(.caption) }
                }
                Section("Review transcript") {
                    TextEditor(text: $transcript).frame(minHeight: 180)
                    if !transcript.isEmpty { ShareLink(item: transcript) { Label("Share reviewed text", systemImage: "square.and.arrow.up") } }
                }
            }.navigationTitle("On-device voice")
                .onDisappear { recorder.cancel(); transcriber.cancel(); recording = false }
        }
    }
    private func toggle() async {
        busy = true
        defer { busy = false }
        do {
            if recording {
                let url = try recorder.stop()
                recording = false
                defer { try? FileManager.default.removeItem(at: url) }
                transcript = try await transcriber.transcribe(fileURL: url)
                notice = "Transcribed locally. Review before sharing or sending."
            } else {
                try await recorder.start()
                recording = true
                notice = "Recording up to 60 seconds. Tap stop when finished."
            }
        } catch { recording = false; notice = error.localizedDescription }
    }
}

private struct VaultLab: View {
    @State private var notice = "No demo secret stored."
    @State private var busy = false
    private let key = VaultKey(userID: "demo-alex", name: "demo-totp")
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Device-bound Keychain storage requires a device passcode. Reading a secret requires Face ID, Touch ID, or the device passcode.")
                    Text("This screen uses a public test secret only. TOTP generates a code; the external provider must verify its MFA challenge.").font(.caption).foregroundStyle(.secondary)
                    Button("Store public test secret") { perform(.enroll) }
                    Button("Authenticate and generate test code") { perform(.code) }
                    Button("Remove test secret", role: .destructive) { perform(.remove) }
                }.disabled(busy)
                Section("Status") { if busy { ProgressView() }; Text(notice).textSelection(.enabled) }
            }.navigationTitle("Vault & verification")
        }
    }
    private enum Operation { case enroll, code, remove }
    private func perform(_ operation: Operation) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let vault = try KeychainVault(service: "io.speedhacks.AIPlayground.vault")
                let service = VaultTOTPService(vault: vault)
                switch operation {
                case .enroll:
                    try await service.enroll(base32Secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", for: key)
                    notice = "Public test secret stored in the device Keychain."
                case .code:
                    let code = try await service.code(for: key)
                    notice = "Public test code: \(code). It changes every 30 seconds."
                case .remove:
                    try await vault.remove(key)
                    notice = "Public test secret removed."
                }
            } catch { notice = error.localizedDescription }
        }
    }
}
