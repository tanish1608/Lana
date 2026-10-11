import SwiftUI

/// Native security boundary the vault UI talks to. Tanish's FinanceAI module (SecureVault,
/// DeviceOwnerAuthenticator, TOTP) provides the real implementation on codex/on-device-ai.
public protocol VaultUnlocking {
    /// Device-owner check (Face ID / passcode).
    func authenticateDeviceOwner(reason: String) async throws
    /// Separate second factor. Throws on a wrong, expired or replayed code.
    func verifySecondFactor(code: String) async throws
    var isSimulated: Bool { get }
}

public struct VaultFailure: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Fixture build only. Performs no biometric or authenticator check and says so on screen.
public struct SimulatedVaultUnlocker: VaultUnlocking {
    public init() {}
    public var isSimulated: Bool { true }
    public func authenticateDeviceOwner(reason: String) async throws { try await Task.sleep(nanoseconds: 700_000_000) }
    public func verifySecondFactor(code: String) async throws {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw VaultFailure("Enter all 6 digits.") }
    }
}

struct VaultEntry: Identifiable { let id: String, label: String, scope: String, value: String }

/// Synthetic credentials for the demo. Never real secrets.
private let demoEntries = [
    VaultEntry(id: "v1", label: "Messaging line token", scope: "Send and receive messages", value: "demo_dial_7Q2x-9fLm-aa41"),
    VaultEntry(id: "v2", label: "Bank sandbox connection", scope: "Read balances and transactions", value: "demo_sbx_acc_55e1c0"),
    VaultEntry(id: "v3", label: "Preference history key", scope: "Read past swap decisions", value: "demo_kw_3b9d-11ce"),
    VaultEntry(id: "v4", label: "Payment handle", scope: "Prefill request drafts", value: "@ashwin-demo"),
]

struct VaultScreen: View {
    let unlocker: VaultUnlocking
    let log: [String]
    enum Stage { case locked, checking, secondFactor, verifying, unlocked }
    @State private var stage = Stage.locked
    @State private var error: String?
    @State private var code = ""
    @State private var revealed: Set<String> = []
    @State private var lockAt = Date.distantFuture
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 0).id("top")
                    switch stage {
                    case .locked, .checking: locked
                    case .secondFactor, .verifying: secondFactor
                    case .unlocked: unlocked
                    }
                    if unlocker.isSimulated {
                        Card(padding: 14) { SimulatedNote("Simulated. No Face ID or code check.") }
                    }
                    SectionLabel("Privacy")
                    Card {
                        Text("The model and financial reasoning run on your phone.").fontWeight(.semibold)
                        Text("Messages and connected services receive what they need to work.")
                        Text("The model never sees passwords, tokens or codes.")
                    }
                    .font(.subheadline)
                    SectionLabel("Approvals")
                    Card {
                        if log.isEmpty { Text("Nothing approved yet.").foregroundStyle(Theme.ink3) }
                        ForEach(Array(log.enumerated()), id: \.offset) { _, l in Text(l).font(.subheadline) }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .onChange(of: stage) { _, _ in proxy.scrollTo("top", anchor: .top) } // each stage starts at its heading
            }
            .background(Theme.bg)
            .navigationTitle("Vault")
            .onChange(of: scenePhase) { _, phase in if phase != .active { lock() } }
            .onReceive(timer) { t in now = t; if stage == .unlocked && t >= lockAt { lock(); error = "Vault locked after 60 seconds." } }
        }
    }

    private var locked: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock").font(.system(size: 36)).foregroundStyle(Theme.accent).frame(width: 88, height: 88).background(Theme.accentSoft, in: Circle())
            Text("Vault is locked").font(Theme.display(30))
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad) }
            Button(stage == .checking ? "Checking Face ID…" : "Unlock with Face ID") {
                stage = .checking; error = nil
                Task {
                    do { try await unlocker.authenticateDeviceOwner(reason: "Unlock your vault"); stage = .secondFactor }
                    catch { stage = .locked; self.error = error.localizedDescription }
                }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(stage == .checking)
        }
        .frame(maxWidth: .infinity).padding(.top, 24)
    }

    private var secondFactor: some View {
        VStack(spacing: 14) {
            Text("One more step").font(Theme.display(30))
            Text("Enter your 6-digit authenticator code.").font(.subheadline).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
            TextField("000000", text: $code).font(.system(size: 28, weight: .medium, design: .monospaced)).multilineTextAlignment(.center)
                .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 14)).frame(maxWidth: 220)
                #if os(iOS)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                #endif
                .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
            Button(stage == .verifying ? "Verifying…" : "Verify") {
                stage = .verifying; error = nil
                Task {
                    do { try await unlocker.verifySecondFactor(code: code); stage = .unlocked; lockAt = Date().addingTimeInterval(60); code = "" }
                    catch { stage = .secondFactor; self.error = error.localizedDescription }
                }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(stage == .verifying)
            Button("Cancel") { lock() }.buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.top, 24)
    }

    private var unlocked: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Unlocked").font(Theme.display(30)); Spacer()
                Tag(text: "Locks in \(max(0, Int(lockAt.timeIntervalSince(now))))s", tone: Theme.accent, fill: Theme.accentSoft) }
            Card {
                ForEach(demoEntries) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.label).fontWeight(.semibold)
                            Text(e.scope).font(.caption).foregroundStyle(Theme.ink3)
                            Text(revealed.contains(e.id) ? e.value : "•••• •••• ••••").font(.system(.footnote, design: .monospaced))
                        }
                        Spacer()
                        Button(revealed.contains(e.id) ? "Hide" : "Show") {
                            if revealed.contains(e.id) { revealed.remove(e.id) } else { revealed.insert(e.id) }
                            lockAt = Date().addingTimeInterval(60)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
            Text("Synthetic demo credentials.").font(.caption).foregroundStyle(Theme.ink3).padding(.horizontal, 4)
            Button("Lock now") { lock() }.buttonStyle(PrimaryButtonStyle())
        }
        .privacySensitive()
    }

    private func lock() { stage = .locked; revealed = []; code = ""; lockAt = .distantFuture }
}
