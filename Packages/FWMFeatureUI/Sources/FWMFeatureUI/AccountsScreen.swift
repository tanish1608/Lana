import SwiftUI
import FWMCore

/// Native security boundary the vault UI talks to. Tanish's FinanceAI module (SecureVault,
/// DeviceOwnerAuthenticator, TOTP) provides the real implementation on codex/on-device-ai.
public protocol VaultUnlocking: Sendable {
    /// Device-owner check (Face ID / passcode).
    func authenticateDeviceOwner(reason: String) async throws
    /// Separate second factor. Throws on a wrong, expired or replayed code.
    func verifySecondFactor(code: String) async throws
    var requiresSecondFactor: Bool { get }
    var isSimulated: Bool { get }
}

public extension VaultUnlocking { var requiresSecondFactor: Bool { true } }

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
    let relay: LanaRelayConnection
    var isActive = true
    @State private var authOperation: UUID?
    @State private var messaging = false
    enum Stage { case locked, checking, secondFactor, verifying, unlocked }
    @State private var stage = Stage.locked
    @State private var error: String?
    @State private var code = ""
    @State private var revealed: Set<String> = []
    @State private var lockAt = Date.distantFuture
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    @State private var addNote = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    connected
                    SectionLabel("Sign-in keys")
                    Card {
                        switch stage {
                        case .locked, .checking: locked
                        case .secondFactor, .verifying: secondFactor
                        case .unlocked: unlocked
                        }
                        if unlocker.isSimulated { SimulatedNote("Simulated. No Face ID or code check.") }
                        else { Text("Protected by device authentication. These are synthetic demo keys; provider MFA is not configured.").font(.caption).foregroundStyle(Theme.ink3) }
                    }
                    .id("keys")
                    SectionLabel("Messaging")
                    Card {
                        Text(relay.status).font(.footnote).foregroundStyle(Theme.ink2)
                        Button("Configure messaging relay") { messaging = true }.buttonStyle(GhostButtonStyle())
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
            .onChange(of: stage) { _, _ in withAnimation { proxy.scrollTo("keys", anchor: .center) } } // keep the keys card in view
            }
            .scrollIndicators(.hidden).background { Theme.backdrop }
            .navigationTitle("Accounts")
            .toolbar {
                Button { withAnimation { addNote = true }; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { addNote = false } } } label: {
                    Label("Add", systemImage: "plus").labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                }
            }
            .overlay(alignment: .top) {
                if addNote {
                    SimulatedNote("Simulated. Linking a new account isn’t wired in this build.")
                        .padding(.horizontal, 14).padding(.vertical, 10).background(.regularMaterial, in: Capsule()).raised(22)
                        .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $messaging) { RelaySettings(connection: relay) }
            .onChange(of: isActive) { _, active in if !active { lock() } }
            .onChange(of: scenePhase) { _, phase in if phase == .background || (phase != .active && stage != .checking) { lock() } }
            .onReceive(timer) { t in now = t; if stage == .unlocked && t >= lockAt { lock(); error = "Vault locked after 60 seconds." } }
        }
    }

    private var locked: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.title3).foregroundStyle(Theme.accent).frame(width: 44, height: 44).background(Theme.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) { Text("\(demoEntries.count) keys · Locked").font(.headline); Text("Tokens Lana uses to reach your services").font(.footnote).foregroundStyle(Theme.ink2) }
                Spacer()
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad) }
            Button(stage == .checking ? "Checking Face ID…" : "Unlock with Face ID") {
                stage = .checking; error = nil
                let operation = UUID(); authOperation = operation
                Task {
                    do { try await unlocker.authenticateDeviceOwner(reason: "Unlock your vault")
                        guard authOperation == operation, scenePhase == .active, isActive else { return }
                        stage = unlocker.requiresSecondFactor ? .secondFactor : .unlocked
                        lockAt = Date().addingTimeInterval(60) }
                    catch { if authOperation == operation { stage = .locked; self.error = error.localizedDescription } }
                }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(stage == .checking)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: connected accounts

    private var accounts: [AccountBalance] {
        if case .success(let v) = store.moneyView(store.snapshotPeriod) { return v.accounts }
        return []
    }
    /// Institutions in first-seen order.
    private var institutions: [String] { accounts.reduce(into: [String]()) { if !$0.contains($1.institution) { $0.append($1.institution) } } }

    @ViewBuilder private var connected: some View {
        let all = accounts, synced = DemoStore.day(store.dataset.asOf)
        Text("\(all.count) accounts at \(institutions.count) institutions · demo data").font(.subheadline).foregroundStyle(Theme.ink2).padding(.horizontal, 4)
        if case .success(let v) = store.moneyView(store.snapshotPeriod) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Net worth")
                HeroAmount(cents: v.netWorthCents, size: 40)
                GeometryReader { g in
                    let total = CGFloat(max(all.reduce(0) { $0 + $1.balanceCents }, 1)), w = g.size.width - CGFloat(max(all.count - 1, 0)) * 3
                    HStack(spacing: 3) {
                        ForEach(all, id: \.accountId) { a in
                            Capsule().fill(Self.brand(a.institution).colors[0].gradient).opacity(a.assetOrLiability == .asset ? 1 : 0.35)
                                .frame(width: max(4, w * CGFloat(a.balanceCents) / total))
                        }
                    }
                }
                .frame(height: 12)
                .accessibilityElement().accessibilityLabel(all.map { "\(Self.kindName($0.kind)) \(usd($0.balanceCents))" }.joined(separator: ", "))
                HStack { Text(usd(v.assetsCents)).bold() + Text(" owned"); Spacer(); Text(usd(v.liabilitiesCents)).bold() + Text(" owed") }
                    .font(.footnote).monospacedDigit().foregroundStyle(Theme.ink2)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).raised(24)
        }
        ForEach(institutions, id: \.self) { inst in
            let brand = Self.brand(inst)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(brand.monogram).font(.headline.weight(.bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(LinearGradient(colors: brand.colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: brand.colors[0].opacity(0.35), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inst).font(.headline)
                        HStack(spacing: 5) { Circle().fill(Theme.ok).frame(width: 7, height: 7); Text("Connected · synced \(synced)").font(.caption).foregroundStyle(Theme.ink2) }
                    }
                    Spacer()
                }
                ForEach(all.filter { $0.institution == inst }, id: \.accountId) { a in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.kindName(a.kind)).fontWeight(.semibold)
                            Text(change(a)).font(.caption).foregroundStyle(Theme.ink2).monospacedDigit()
                        }
                        Spacer()
                        Text(usd(a.balanceCents)).font(.title3.weight(.bold)).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
        }
        SectionLabel("Also connected")
        Card {
            service("message.fill", .green, "Messages", "Talk to Lana by text", "Simulated here")
            Divider()
            service("arrow.up.right.square.fill", .blue, "Venmo", "Lana never holds your login", "Handoff")
            Divider()
            service("bag.fill", .orange, "Purchase history", "Past swap decisions", "Simulated here")
        }
    }

    /// Month's change from the seed's opening balance; liabilities read as what you owe.
    private func change(_ a: AccountBalance) -> String {
        if a.assetOrLiability == .liability { return "You owe" }
        let month = DemoStore.monthName(store.snapshotPeriod, short: true)
        guard let open = store.dataset.accounts.first(where: { $0.accountId == a.accountId })?.openingBalanceCents else { return "Balance" }
        let d = a.balanceCents - open
        return d == 0 ? "No change in \(month)" : "\(usd(d, plus: true)) in \(month)"
    }

    private func service(_ icon: String, _ color: Color, _ title: String, _ sub: String, _ tag: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.white).frame(width: 36, height: 36)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) { Text(title).fontWeight(.semibold); Text(sub).font(.caption).foregroundStyle(Theme.ink2) }
            Spacer()
            Tag(text: tag, tone: tag == "Handoff" ? Theme.accent : Theme.warn, fill: tag == "Handoff" ? Theme.accentSoft : Theme.warnSoft)
        }
    }

    private static func kindName(_ kind: String) -> String {
        ["checking": "Checking", "savings": "Savings", "brokerage": "Brokerage", "credit_card": "Credit card", "student_loan": "Student loan"][kind]
            ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Demo institution colours, matched on the name so new fixture institutions still get a sensible mark.
    private static func brand(_ institution: String) -> (monogram: String, colors: [Color]) {
        let n = institution.lowercased()
        let letter = String(institution.replacingOccurrences(of: "Demo ", with: "").prefix(1)).uppercased()
        if n.contains("broker") { return (letter, [Color(light: 0x34C759, dark: 0x30D158), Color(light: 0x248A3D, dark: 0x248A3D)]) }
        if n.contains("card") { return (letter, [Color(light: 0x636366, dark: 0x8E8E93), Color(light: 0x2C2C2E, dark: 0x48484A)]) }
        if n.contains("loan") { return (letter, [Color(light: 0xFF9F0A, dark: 0xFF9F0A), Color(light: 0xFF6B00, dark: 0xFF6B00)]) }
        return (letter, [Color(light: 0x0A84FF, dark: 0x0A84FF), Color(light: 0x5E5CE6, dark: 0x5E5CE6)])
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

    private func lock() { authOperation = nil; stage = .locked; revealed = []; code = ""; lockAt = .distantFuture }
}
