import SwiftUI
import PhotosUI
import Observation
import FinanceAI
import FWMCore

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
