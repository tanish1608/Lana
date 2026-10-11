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
    /// The current session dataset (fixture plus any accounts imported on this phone).
    let dataset: Dataset
    let unlocker: VaultUnlocking
    let log: [String]
    let relay: LanaRelayConnection
    var isActive = true
    var onLink: (Account, [FWMCore.Transaction]) -> Void = { _, _ in }
    var onRemove: (String) -> Void = { _ in }
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
    @State private var linking = false

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
            .background { Theme.backdrop }
            .navigationTitle("Accounts")
            .navigationDestination(for: String.self) { id in AccountDetailView(dataset: dataset, period: store.snapshotPeriod, accountID: id, onRemove: onRemove) }
            .toolbar {
                Button { linking = true } label: {
                    Label("Add account", systemImage: "plus").labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                }
            }
            .sheet(isPresented: $linking) { LinkAccountSheet(user: dataset.user, onLink: onLink) }
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

    private var view: MoneyView? { try? MoneyEngine.moneyView(dataset, period: store.snapshotPeriod) }
    /// Institutions in first-seen order.
    private func institutions(_ all: [AccountBalance]) -> [String] { all.reduce(into: [String]()) { if !$0.contains($1.institution) { $0.append($1.institution) } } }

    @ViewBuilder private var connected: some View {
        if let v = view {
            let all = v.accounts, imported = all.contains { AccountDisplay($0).isImported }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow("Net worth")
                    Spacer()
                    Text("\(all.count) accounts · \(institutions(all).count) institutions").font(.caption).foregroundStyle(Theme.ink2)
                }
                HeroAmount(cents: v.netWorthCents, size: 40)
                GeometryReader { g in
                    let assets = all.filter { $0.assetOrLiability == .asset }
                    let total = CGFloat(max(assets.reduce(0) { $0 + $1.balanceCents }, 1)), w = g.size.width - CGFloat(max(assets.count - 1, 0)) * 3
                    HStack(spacing: 3) {
                        ForEach(assets, id: \.accountId) { a in
                            Capsule().fill(AccountDisplay(a).color.gradient).frame(width: max(4, w * CGFloat(a.balanceCents) / total))
                        }
                    }
                }
                .frame(height: 10)
                .accessibilityElement().accessibilityLabel(all.map { "\(AccountDisplay($0).title) \(usd($0.balanceCents))" }.joined(separator: ", "))
                HStack { Text(usd(v.assetsCents)).bold() + Text(" assets"); Spacer(); Text(usd(v.liabilitiesCents)).bold() + Text(" debt") }
                    .font(.footnote).monospacedDigit().foregroundStyle(Theme.ink2)
                Text(imported ? "Sample data plus statements imported on this iPhone" : "Sample data · balances as of \(DemoStore.day(dataset.asOf))")
                    .font(.caption).foregroundStyle(Theme.ink3)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).raised(24)

            ForEach(AccountKind.Group.allCases, id: \.self) { group in
                let list = all.filter { AccountKind.group($0.kind) == group }
                if !list.isEmpty {
                    HStack {
                        SectionLabel(group.title)
                        Spacer()
                        Text(usd(list.reduce(0) { $0 + $1.balanceCents })).font(.footnote.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Theme.ink2).padding(.top, 18).padding(.horizontal, 16)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.accountId) { n, a in
                            if n > 0 { Divider().padding(.leading, 68) }
                            NavigationLink(value: a.accountId) { accountRow(a) }.buttonStyle(.plain)
                        }
                    }
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
                }
            }

            SectionLabel("Connections")
            VStack(spacing: 0) {
                ForEach(Array(institutions(all).enumerated()), id: \.element) { n, inst in
                    let accounts = all.filter { $0.institution == inst }
                    let csv = accounts.contains { AccountDisplay($0).isImported }
                    if n > 0 { Divider().padding(.leading, 62) }
                    HStack(spacing: 12) {
                        InstitutionLogo(name: inst, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inst).fontWeight(.semibold)
                            Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s") · \(csv ? "imported statement" : "sample data")")
                                .font(.caption).foregroundStyle(Theme.ink2)
                        }
                        Spacer()
                        HStack(spacing: 5) { Circle().fill(Theme.ok).frame(width: 7, height: 7); Text(csv ? "Imported" : "Up to date").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink2) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
                Divider().padding(.leading, 62)
                Button { linking = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.headline).foregroundStyle(Theme.accent).frame(width: 36, height: 36)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text("Add an account").fontWeight(.semibold).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
        }
        SectionLabel("Also connected")
        Card {
            service(AnyView(symbolMark("message.fill", .green)), "Messages", "Talk to Lana by text", "Simulated here")
            Divider()
            service(AnyView(InstitutionLogo(name: "Venmo", size: 36)), "Venmo", "Request handoff. Lana never holds your login.", "Handoff")
            Divider()
            service(AnyView(symbolMark("bag.fill", .orange)), "Purchase history", "Past swap decisions", "Simulated here")
        }
    }

    private func accountRow(_ a: AccountBalance) -> some View {
        let d = AccountDisplay(a)
        return HStack(spacing: 12) {
            InstitutionLogo(name: a.institution, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.8)
                Text("\(a.institution) · \(d.subtitle)").font(.caption).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(usd(a.balanceCents, cents: true)).font(.body.weight(.semibold)).monospacedDigit()
                Text(change(a)).font(.caption).foregroundStyle(Theme.ink2).monospacedDigit()
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Month's change from the seed's opening balance; liabilities read as what you owe.
    private func change(_ a: AccountBalance) -> String {
        if a.assetOrLiability == .liability { return "Owed" }
        let month = DemoStore.monthName(store.snapshotPeriod, short: true)
        guard let open = dataset.accounts.first(where: { $0.accountId == a.accountId })?.openingBalanceCents else { return "Imported" }
        let d = a.balanceCents - open
        return d == 0 ? "No change in \(month)" : "\(usd(d, plus: true)) in \(month)"
    }

    private func symbolMark(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.white).frame(width: 36, height: 36)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func service(_ mark: AnyView, _ title: String, _ sub: String, _ tag: String) -> some View {
        HStack(spacing: 12) {
            mark
            VStack(alignment: .leading, spacing: 1) { Text(title).fontWeight(.semibold); Text(sub).font(.caption).foregroundStyle(Theme.ink2) }
            Spacer()
            Tag(text: tag, tone: tag == "Handoff" ? Theme.accent : Theme.warn, fill: tag == "Handoff" ? Theme.accentSoft : Theme.warnSoft)
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

    private func lock() { authOperation = nil; stage = .locked; revealed = []; code = ""; lockAt = .distantFuture }
}
