import SwiftUI
import FWMCore

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

/// Everything Lana is connected to: financial accounts first, then the access keys behind Face ID.
struct AccountsScreen: View {
    let store: DemoStore
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
                    connected
                    SectionLabel("Access keys")
                    Card {
                        switch stage {
                        case .locked, .checking: locked
                        case .secondFactor, .verifying: secondFactor
                        case .unlocked: unlocked
                        }
                        if unlocker.isSimulated { SimulatedNote("Simulated. No Face ID or code check.") }
                    }
                    .id("keys")
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
            .onChange(of: stage) { _, _ in withAnimation { proxy.scrollTo("keys", anchor: .center) } } // keep the keys card in view
            }
            .background(Theme.bg)
            .navigationTitle("Accounts")
            .toolbar { DemoDataBadge() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { lock() } }
            .onReceive(timer) { t in now = t; if stage == .unlocked && t >= lockAt { lock(); error = "Vault locked after 60 seconds." } }
        }
    }

    private var locked: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.title3).foregroundStyle(Theme.accent).frame(width: 44, height: 44).background(Theme.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) { Text("Locked").font(.headline); Text("\(demoEntries.count) keys and tokens").font(.footnote).foregroundStyle(Theme.ink2) }
                Spacer()
            }
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
        .frame(maxWidth: .infinity)
    }

    private var connected: some View {
        let accounts: [AccountBalance] = { if case .success(let v) = store.moneyView(store.snapshotPeriod) { return v.accounts }; return [] }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(accounts.count)").font(.system(size: 56, weight: .bold)).monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Text("accounts connected").font(.headline)
                    Text("\(Set(accounts.map(\.institution)).count) institutions").font(.footnote).foregroundStyle(Theme.ink2)
                }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 10) {
                ForEach(accounts, id: \.accountId) { a in
                    let style = Self.style(a.kind)
                    HStack(spacing: 12) {
                        Image(systemName: style.icon).font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(style.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: style.color.opacity(0.35), radius: 6, y: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.name).fontWeight(.semibold)
                            HStack(spacing: 5) {
                                Circle().fill(Theme.ok).frame(width: 7, height: 7)
                                Text("\(a.institution) · \(DemoStore.day(a.asOf))").font(.caption).foregroundStyle(Theme.ink2)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(usd(a.balanceCents)).fontWeight(.semibold).monospacedDigit()
                            Text(a.assetOrLiability == .asset ? "owned" : "owed").font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                    .padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).raised(18)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private static func style(_ kind: String) -> (name: String, icon: String, color: Color) {
        switch kind {
        case "checking": return ("Checking", "building.columns.fill", .blue)
        case "savings": return ("Savings", "banknote.fill", .green)
        case "brokerage": return ("Brokerage", "chart.line.uptrend.xyaxis", .indigo)
        case "credit_card": return ("Credit card", "creditcard.fill", .orange)
        case "student_loan": return ("Student loan", "graduationcap.fill", .pink)
        default: return (kind.replacingOccurrences(of: "_", with: " ").capitalized, "wallet.pass.fill", .gray)
        }
    }

    private var secondFactor: some View {
        VStack(spacing: 14) {
            Text("One more step").font(.headline)
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
        .frame(maxWidth: .infinity)
    }

    private var unlocked: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Unlocked").font(.headline); Spacer()
                Tag(text: "Locks in \(max(0, Int(lockAt.timeIntervalSince(now))))s", tone: Theme.accent, fill: Theme.accentSoft) }
            VStack(alignment: .leading, spacing: 10) {
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
