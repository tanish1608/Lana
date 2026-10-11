import SwiftUI
import FWMCore
import FinanceAI

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

/// Everything Lana is connected to, behind Face ID: balances and accounts, saved connections, privacy, approvals.
/// The page locks when you leave the tab, when the app goes to the background, and after five minutes.
struct AccountsScreen: View {
    let store: DemoStore
    /// The current session dataset (fixture plus any accounts imported on this phone).
    let dataset: Dataset
    let unlocker: VaultUnlocking
    let log: [String]
    let relay: LanaRelayConnection
    let chat: LanaChatController
    var isActive = true
    var onLink: (Account, [FWMCore.Transaction]) -> Void = { _, _ in }
    var onConnect: (URL, String, [String]) -> Void = { _, _, _ in }
    var onRemove: (String) -> Void = { _ in }
    @State private var authOperation: UUID?
    @State private var messaging = false
    enum Stage { case locked, checking, secondFactor, verifying, unlocked }
    @State private var stage = Stage.locked
    @State private var error: String?
    @State private var code = ""
    @State private var lockAt = Date.distantFuture
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    @State private var linking = false
    @State private var working: String?
    @State private var connectionNote: String?
    /// Read by the app entry point, which reloads Lana with the chosen bundled dataset.
    @AppStorage(DemoStore.Choice.storageKey) private var dataChoice = DemoStore.Choice.threeYear.rawValue
    private static let unlockedFor: TimeInterval = 300
    #if DEBUG
    /// Xcode previews and screenshot renders only; release builds always start locked.
    var previewUnlocked = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch stage {
                    case .unlocked:
                        connected
                        SectionLabel("Saved connections")
                        connections
                        SectionLabel("Data")
                        Card {
                            Picker("Data", selection: $dataChoice) {
                                ForEach(DemoStore.Choice.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }
                            .pickerStyle(.segmented)
                            Text(dataChoice == DemoStore.Choice.threeYear.rawValue
                                 ? "Synthetic history, Oct 2023 – Sep 2026, across 14 accounts. Linked and imported accounts are added on top."
                                 : "One synthetic month, September 2026, for the walkthrough. Linked and imported accounts are added on top.")
                                .font(.caption).foregroundStyle(Theme.ink2)
                        }
                        SectionLabel("Privacy")
                        Card {
                            Text("The model and financial reasoning run on your phone.").fontWeight(.semibold)
                            Text("Banks and messaging receive only what they need to work.")
                            Text("The model never sees passwords, tokens or codes.")
                        }
                        .font(.subheadline)
                        SectionLabel("Approvals")
                        Card {
                            if log.isEmpty { Text("Nothing approved yet.").foregroundStyle(Theme.ink3) }
                            ForEach(Array(log.enumerated()), id: \.offset) { _, l in Text(l).font(.subheadline) }
                        }
                    case .secondFactor, .verifying: Card { secondFactor }.padding(.top, 40)
                    case .locked, .checking: locked
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden).background { Theme.backdrop }
            .navigationTitle("Accounts")
            .navigationDestination(for: String.self) { id in AccountDetailView(dataset: dataset, period: store.snapshotPeriod, accountID: id, onRemove: onRemove) }
            .toolbar {
                if stage == .unlocked {
                    Button { linking = true } label: {
                        Label("Add account", systemImage: "plus").labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                    }
                    Button { lock() } label: { Image(systemName: "lock.fill") }.accessibilityLabel("Lock accounts")
                }
            }
            .sheet(isPresented: $linking) { LinkAccountSheet(user: dataset.user, onLink: onLink, onConnect: onConnect) }
            .sheet(isPresented: $messaging) { RelaySettings(connection: relay) }
            .onChange(of: isActive) { _, active in if !active { lock() } }
            .onChange(of: scenePhase) { _, phase in if phase == .background || (phase != .active && stage != .checking) { lock() } }
            .onReceive(timer) { t in now = t; if stage == .unlocked && t >= lockAt { lock(); error = "Locked after 5 minutes." } }
            #if DEBUG
            .onAppear { if previewUnlocked { stage = .unlocked; lockAt = Date().addingTimeInterval(Self.unlockedFor) } }
            #endif
        }
    }

    /// Shown until device-owner authentication succeeds: no balances, institutions or connections are rendered.
    private var locked: some View {
        VStack(spacing: 18) {
            Image(systemName: "faceid").font(.system(size: 56, weight: .light)).foregroundStyle(Theme.accent)
                .frame(width: 110, height: 110).background(Theme.cardFill, in: Circle()).raised(55).padding(.top, 70)
            VStack(spacing: 6) {
                Text("Accounts are locked").font(Theme.display(26))
                Text("Balances, linked banks and saved connections need Face ID.").foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad) }
            Button(stage == .checking ? "Checking Face ID…" : "Unlock with Face ID") { unlock() }
                .buttonStyle(PrimaryButtonStyle()).disabled(stage == .checking)
            if unlocker.isSimulated { SimulatedNote("Preview build: no Face ID on this device.") }
        }
        .frame(maxWidth: .infinity)
    }

    private func unlock() {
        stage = .checking; error = nil
        let operation = UUID(); authOperation = operation
        Task {
            do {
                try await unlocker.authenticateDeviceOwner(reason: "Unlock your accounts")
                guard authOperation == operation, scenePhase == .active, isActive else { return }
                stage = unlocker.requiresSecondFactor ? .secondFactor : .unlocked
                lockAt = Date().addingTimeInterval(Self.unlockedFor)
            } catch { if authOperation == operation { stage = .locked; self.error = error.localizedDescription } }
        }
    }

    /// What Lana actually keeps: the messaging relay pairing and SimpleFIN bank links. Credentials stay in the
    /// Keychain and are never displayed; refreshing reads one with Face ID.
    @ViewBuilder private var connections: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                symbolMark("message.fill", .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messaging relay").fontWeight(.semibold)
                    Text(relay.connected ? "Paired · answers texts and calls while Lana is open" : "Not paired").font(.caption).foregroundStyle(Theme.ink2)
                }
                Spacer()
                Button(relay.connected ? "Manage" : "Pair") { messaging = true }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            ForEach(chat.connections) { c in
                Divider().padding(.leading, 62)
                HStack(spacing: 12) {
                    InstitutionLogo(name: c.label.components(separatedBy: " via ").first ?? c.label, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label).fontWeight(.semibold).lineLimit(1)
                        Text("\(c.accountIDs.count) account\(c.accountIDs.count == 1 ? "" : "s") · " + (c.refreshedAt.map { "refreshed \($0.formatted(.relative(presentation: .named)))" } ?? "not refreshed"))
                            .font(.caption).foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                    if working == c.id { ProgressView().controlSize(.small) }
                    else {
                        Menu {
                            Button("Refresh", systemImage: "arrow.clockwise") { run(c.id) { try await chat.refresh(c) } }
                            Button("Disconnect", systemImage: "minus.circle", role: .destructive) { run(c.id) { await chat.removeConnection(c); return "Disconnected \(c.label)." } }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.accent) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
            if chat.connections.isEmpty {
                Divider().padding(.leading, 62)
                Button { linking = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link").font(.headline).foregroundStyle(Theme.accent).frame(width: 36, height: 36)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text("Link a bank with SimpleFIN").fontWeight(.semibold).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
        if let connectionNote { Text(connectionNote).font(.caption).foregroundStyle(Theme.ink2).padding(.horizontal, 4) }
        Text("Credentials are kept in this iPhone's Keychain, need Face ID to use, and are never shown or given to the model.")
            .font(.caption).foregroundStyle(Theme.ink3).padding(.horizontal, 4)
    }

    private func run(_ id: String, _ work: @escaping @MainActor () async throws -> String) {
        working = id; connectionNote = nil
        Task { @MainActor in
            defer { working = nil }
            do { connectionNote = try await work(); lockAt = Date().addingTimeInterval(Self.unlockedFor) }
            catch { connectionNote = (error as? ToolError)?.userMessage ?? error.localizedDescription }
        }
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
                Text(imported ? "Sample data plus accounts you added on this iPhone" : "Sample data · balances as of \(DemoStore.day(dataset.asOf))")
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

            SectionLabel("Institutions")
            VStack(spacing: 0) {
                ForEach(Array(institutions(all).enumerated()), id: \.element) { n, inst in
                    let accounts = all.filter { $0.institution == inst }
                    let csv = accounts.contains { AccountDisplay($0).isImported }
                    let link = accounts.contains { AccountDisplay($0).isLinked }
                    if n > 0 { Divider().padding(.leading, 62) }
                    HStack(spacing: 12) {
                        InstitutionLogo(name: inst, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inst).fontWeight(.semibold)
                            Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s") · \(link ? "SimpleFIN" : csv ? "imported statement" : "sample data")")
                                .font(.caption).foregroundStyle(Theme.ink2)
                        }
                        Spacer()
                        HStack(spacing: 5) { Circle().fill(Theme.ok).frame(width: 7, height: 7); Text(link ? "Linked" : csv ? "Imported" : "Up to date").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink2) }
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
        SectionLabel("Also used")
        Card {
            service(AnyView(InstitutionLogo(name: "Venmo", size: 36)), "Venmo", "Lana drafts requests; you send them in Venmo.", "Drafts")
            Divider()
            service(AnyView(symbolMark("bag.fill", .orange)), "Swap history", "Past swap decisions shape budget ideas.", "Sample history")
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
        guard let open = dataset.accounts.first(where: { $0.accountId == a.accountId })?.openingBalanceCents else { return AccountDisplay(a).isLinked ? "Linked" : "Imported" }
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
            Tag(text: tag, tone: tag == "Drafts" ? Theme.accent : Theme.ink2, fill: tag == "Drafts" ? Theme.accentSoft : Theme.line)
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
                    do { try await unlocker.verifySecondFactor(code: code); stage = .unlocked; lockAt = Date().addingTimeInterval(Self.unlockedFor); code = "" }
                    catch { stage = .secondFactor; self.error = error.localizedDescription }
                }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(stage == .verifying)
            Button("Cancel") { lock() }.buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func lock() { authOperation = nil; stage = .locked; code = ""; lockAt = .distantFuture; linking = false }
}
