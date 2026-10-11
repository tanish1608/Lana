import SwiftUI
import UniformTypeIdentifiers
import FWMCore

/// One statement export turned into a dataset account through FWMCore's BankCSVProvider. Nothing leaves the device.
struct StatementImport {
    let institution: Institution
    let kind: String
    let balanceCents: Int
    let csv: String
    let user: UserPrefs
    /// Card exports often list purchases as positive numbers; the dataset needs money leaving as negative.
    var flipSigns = false

    struct Output {
        var account: Account
        var transactions: [FWMCore.Transaction]
        var warnings: [String]
    }

    func run(accountID: String, asOf: String) throws -> Output {
        let statement = CSVStatement(accountId: accountID, institution: institution.name, kind: kind, side: AccountKind.side(kind),
                                     balanceCents: balanceCents, csv: csv)
        let (ds, status) = try BankCSVProvider(statements: [statement], user: user, asOf: asOf).fetch()
        guard let account = ds.accounts.first else { throw ToolError(.invalidArguments, "The file didn't contain an account.") }
        var txns = ds.transactions
        if flipSigns { for i in txns.indices { txns[i].signedAmountCents = -txns[i].signedAmountCents } }
        guard !txns.isEmpty else { throw ToolError(.invalidArguments, "No transactions were readable in this file.") }
        // The provider pairs transfers within one import; a single statement has no counterpart, so drop those notes.
        return Output(account: account, transactions: txns, warnings: status.warnings.filter { !$0.contains("transfer") })
    }

    /// True when most non-transfer rows are positive, which for a card or loan export means purchases were listed as positive.
    static func chargesLookPositive(_ txns: [FWMCore.Transaction]) -> Bool {
        let signs = txns.filter { $0.transferPairId == nil }.map(\.signedAmountCents)
        return signs.filter { $0 > 0 }.count > signs.filter { $0 < 0 }.count
    }

    /// Nonnegative USD with at most two decimals ("1,234.5", "$80") to integer cents.
    static func cents(_ raw: String) -> Int? {
        let s = raw.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !s.isEmpty, parts.count <= 2, let whole = Int(parts[0].isEmpty ? "0" : parts[0]), whole >= 0, whole < 100_000_000 else { return nil }
        guard parts.count == 2 else { return whole * 100 }
        let frac = parts[1]
        guard frac.count <= 2, frac.allSatisfy(\.isNumber) else { return nil }
        return whole * 100 + (Int(frac.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0)
    }
}

/// Add-account onboarding: why connect, pick an institution, choose how to connect, import and review, done.
struct LinkAccountSheet: View {
    let user: UserPrefs
    var onLink: (Account, [FWMCore.Transaction]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var linked: (account: Account, count: Int)?

    enum Step: Hashable { case pick, connect(String), statement(String), done }

    var body: some View {
        NavigationStack(path: $path) {
            intro
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .pick: InstitutionPicker { path.append(.connect($0.id)) }
                    case .connect(let id): if let i = Institution.id(id) { ConnectInstitutionView(institution: i) { path.append(.statement(id)) } }
                    case .statement(let id):
                        if let i = Institution.id(id) {
                            StatementImportView(institution: i, user: user) { account, txns in
                                onLink(account, txns); linked = (account, txns.count); path.append(.done)
                            }
                        }
                    case .done: done
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }

    private var intro: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    ForEach(Array(["chase", "bank_of_america", "robinhood", "american_express"].enumerated()), id: \.offset) { i, id in
                        InstitutionLogo(name: Institution.id(id)?.name ?? id, size: 54)
                            .rotationEffect(.degrees(Double(i - 1) * 8 - 4))
                            .offset(x: CGFloat(i) * 44 - 66, y: i % 2 == 0 ? 6 : -6)
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    }
                    LanaOrb(size: 64).offset(y: 52).shadow(color: Theme.auraViolet.opacity(0.5), radius: 12, y: 6)
                }
                .frame(height: 150).padding(.top, 12)
                VStack(spacing: 8) {
                    Text("Connect your accounts").font(Theme.display(28)).multilineTextAlignment(.center)
                    Text("See every balance in one place, and let Lana answer with your actual numbers.")
                        .font(.body).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 16) {
                    bullet("eye", "Read-only", "Lana sees balances and transactions. It can’t move money or make payments.")
                    bullet("iphone", "Private by design", "Your financial data is analyzed on this iPhone. The model never sees passwords.")
                    bullet("hand.raised", "You’re in control", "Choose which accounts to add, and remove them at any time.")
                }
                .padding(18).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
                Button("Continue") { path.append(.pick) }.buttonStyle(PrimaryButtonStyle())
                Text("By continuing you choose what to share with Lana on this device.").font(.caption).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background { Theme.backdrop }
    }

    private func bullet(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 36, height: 36).background(Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(title).fontWeight(.semibold); Text(text).font(.subheadline).foregroundStyle(Theme.ink2) }
        }
    }

    @ViewBuilder private var done: some View {
        if let linked {
            let display = AccountDisplay(linked.account)
            VStack(spacing: 18) {
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    InstitutionLogo(name: linked.account.institution, size: 88).shadow(color: display.color.opacity(0.35), radius: 16, y: 8)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.white, Theme.ok).background(Circle().fill(.white).padding(4)).offset(x: 12, y: 12)
                }
                Text("You’re all set").font(Theme.display(28))
                Text("\(display.title) ••\(display.mask) is now in Lana with \(linked.count) transactions.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.ink2)
                Text("Imported on this iPhone for this session. Nothing was uploaded.").font(.caption).foregroundStyle(Theme.ink3)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                Button("Add another account") { self.linked = nil; path = [.pick] }.buttonStyle(GhostButtonStyle())
            }
            .padding(20)
            .navigationBarBackButtonHidden()
            .background { Theme.backdrop }
        }
    }
}

/// Searchable institution list with a logo grid of the most common ones.
struct InstitutionPicker: View {
    var onPick: (Institution) -> Void
    @State private var query = ""
    private var results: [Institution] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return Institution.all.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.domain.contains(q) || $0.aliases.contains { $0.contains(q) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if query.isEmpty {
                    SectionLabel("Popular")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(Institution.popular.compactMap(Institution.id)) { i in
                            Button { onPick(i) } label: {
                                VStack(spacing: 8) {
                                    InstitutionLogo(name: i.name, size: 52)
                                    Text(i.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).raised(16)
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                }
                ForEach(Institution.Category.allCases, id: \.self) { category in
                    let list = results.filter { $0.category == category }
                    if !list.isEmpty {
                        SectionLabel(category.rawValue)
                        VStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { n, i in
                                if n > 0 { Divider().padding(.leading, 66) }
                                Button { onPick(i) } label: {
                                    HStack(spacing: 12) {
                                        InstitutionLogo(name: i.name, size: 38)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(i.name).fontWeight(.semibold).foregroundStyle(Theme.ink)
                                            Text(i.domain).font(.caption).foregroundStyle(Theme.ink2)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).raised(16)
                    }
                }
                if results.isEmpty {
                    Text("No match for “\(query)”. Lana lists the institutions it has logos and account types for.")
                        .font(.subheadline).foregroundStyle(Theme.ink2).padding(.top, 24).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background { Theme.backdrop }
        .navigationTitle("Select your institution")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search banks, cards, brokerages")
        #else
        .searchable(text: $query, prompt: "Search banks, cards, brokerages")
        #endif
    }
}

/// How this institution can be connected, and what Lana will and won't be able to do.
struct ConnectInstitutionView: View {
    let institution: Institution
    var onImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 14) {
                    LanaOrb(size: 56)
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.ink3).frame(width: 5, height: 5) } }
                    InstitutionLogo(name: institution.name, size: 64).shadow(color: institution.color.opacity(0.3), radius: 10, y: 5)
                }
                .padding(.top, 16)
                VStack(spacing: 6) {
                    Text("Connect \(institution.name)").font(Theme.display(26)).multilineTextAlignment(.center)
                    Text("Bring your \(institution.name) accounts into Lana.").foregroundStyle(Theme.ink2)
                }
                Button(action: onImport) {
                    option(icon: "doc.text", title: "Import from \(institution.domain)",
                           text: "Download your account activity as a CSV and choose the file. It’s read on this iPhone.", tag: "Recommended", enabled: true)
                }
                .buttonStyle(PressScaleStyle())
                option(icon: "person.badge.key", title: "Sign in to \(institution.name)",
                       text: "Direct sign-in needs a bank-data partner, which isn’t set up in this build.", tag: "Not available yet", enabled: false)
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Lana will be able to")
                    Label("See balances and transactions", systemImage: "checkmark").foregroundStyle(Theme.ok)
                    Label("Answer questions and build budgets from them", systemImage: "checkmark").foregroundStyle(Theme.ok)
                    Eyebrow("Lana won’t").padding(.top, 6)
                    Label("Move money or make payments", systemImage: "xmark").foregroundStyle(Theme.bad)
                    Label("See your \(institution.name) password", systemImage: "xmark").foregroundStyle(Theme.bad)
                }
                .font(.subheadline.weight(.medium))
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
            }
            .padding(20)
        }
        .background { Theme.backdrop }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func option(icon: String, title: String, text: String, tag: String, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(enabled ? .white : Theme.ink3).frame(width: 44, height: 44)
                .background(enabled ? AnyShapeStyle(institution.color.gradient) : AnyShapeStyle(Theme.line), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(title).fontWeight(.semibold).foregroundStyle(enabled ? Theme.ink : Theme.ink2); Spacer()
                    Tag(text: tag, tone: enabled ? Theme.ok : Theme.ink2, fill: enabled ? Theme.okSoft : Theme.line) }
                Text(text).font(.subheadline).foregroundStyle(Theme.ink2).multilineTextAlignment(.leading)
            }
            if enabled { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3).padding(.top, 14) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
        .opacity(enabled ? 1 : 0.75)
        .accessibilityElement(children: .combine)
    }
}

/// Account type, current balance and the CSV file; previews exactly what will be added before anything changes.
struct StatementImportView: View {
    let institution: Institution
    let user: UserPrefs
    var onAdd: (Account, [FWMCore.Transaction]) -> Void
    @State private var kind: String
    @State private var balance = ""
    @State private var csv: (name: String, text: String)?
    @State private var flip = false
    @State private var importing = false
    @State private var error: String?
    @State private var accountID = "csv_" + UUID().uuidString.prefix(8).lowercased()

    init(institution: Institution, user: UserPrefs, onAdd: @escaping (Account, [FWMCore.Transaction]) -> Void) {
        self.institution = institution; self.user = user; self.onAdd = onAdd
        _kind = State(initialValue: institution.kinds.first ?? "checking")
    }

    private var liability: Bool { AccountKind.side(kind) == .liability }
    private var balanceCents: Int? { StatementImport.cents(balance) }
    private var preview: Result<StatementImport.Output, Error>? {
        guard let csv else { return nil }
        let job = StatementImport(institution: institution, kind: kind, balanceCents: balanceCents ?? 0, csv: csv.text, user: user, flipSigns: flip)
        return Result { try job.run(accountID: accountID, asOf: Self.now()) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    InstitutionLogo(name: institution.name, size: 44)
                    VStack(alignment: .leading, spacing: 1) { Text(institution.product(kind)).font(.headline); Text(institution.domain).font(.caption).foregroundStyle(Theme.ink2) }
                }
                .padding(.horizontal, 4)
                SectionLabel("Account")
                Card {
                    if institution.kinds.count > 1 {
                        Picker("Account type", selection: $kind) { ForEach(institution.kinds, id: \.self) { Text(AccountKind.name($0)).tag($0) } }
                            .pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(liability ? "Amount you owe today" : "Current balance").font(.subheadline.weight(.semibold))
                        TextField("$0.00", text: $balance).font(.title2.weight(.semibold)).monospacedDigit()
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        if !balance.isEmpty && balanceCents == nil { Text("Enter dollars and cents, like 1,250.00.").font(.caption).foregroundStyle(Theme.bad) }
                        else { Text("As shown on \(institution.domain). Statement files don’t include it.").font(.caption).foregroundStyle(Theme.ink3) }
                    }
                }
                SectionLabel("Activity")
                Card {
                    Button { importing = true } label: {
                        Label(csv?.name ?? "Choose CSV file", systemImage: csv == nil ? "square.and.arrow.down" : "doc.text.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GhostButtonStyle())
                    DisclosureGroup("How to download it") {
                        Text("Sign in at \(institution.domain), open the account, and download its activity (often under Statements or Download) as a CSV file. Lana reads Date, Description and Amount columns, plus Category and Status when present.")
                            .font(.footnote).foregroundStyle(Theme.ink2).padding(.top, 6)
                    }
                    .font(.subheadline.weight(.semibold))
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad) }
                }
                if let preview { previewCard(preview) }
                let ready = balanceCents != nil && (try? preview?.get()) != nil
                Button("Add account") {
                    guard let out = try? preview?.get() else { return }
                    onAdd(out.account, out.transactions)
                }
                .buttonStyle(PrimaryButtonStyle(fill: ready ? institution.color : Theme.ink3)).disabled(!ready).padding(.top, 8)
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background { Theme.backdrop }
        .navigationTitle("Import activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            error = nil
            do { csv = try Self.read(try result.get()) } catch { self.error = error.localizedDescription }
            if let out = try? preview?.get(), liability { flip = StatementImport.chargesLookPositive(out.transactions) }
        }
    }

    @ViewBuilder private func previewCard(_ result: Result<StatementImport.Output, Error>) -> some View {
        SectionLabel("Preview")
        Card {
            switch result {
            case .failure(let e):
                Label((e as? ToolError)?.userMessage ?? e.localizedDescription, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad)
            case .success(let out):
                let dates = out.transactions.map { String($0.postedAt.prefix(10)) }.sorted()
                let inflow = out.transactions.filter { $0.signedAmountCents > 0 }.reduce(0) { $0 + $1.signedAmountCents }
                let outflow = out.transactions.filter { $0.signedAmountCents < 0 }.reduce(0) { $0 - $1.signedAmountCents }
                Text("\(out.transactions.count) transactions · \(Self.day(dates.first)) – \(Self.day(dates.last))").font(.headline)
                HStack {
                    VStack(alignment: .leading) { Eyebrow("Money in"); Text(usd(inflow, cents: true)).font(.title3.weight(.bold)).foregroundStyle(Theme.ok) }
                    Spacer()
                    VStack(alignment: .trailing) { Eyebrow("Money out"); Text(usd(outflow, cents: true)).font(.title3.weight(.bold)) }
                }
                .monospacedDigit()
                Divider()
                ForEach(out.transactions.sorted { $0.postedAt > $1.postedAt }.prefix(4), id: \.transactionId) { t in
                    TransactionRow(transaction: t)
                }
                if liability {
                    Toggle("Purchases are listed as positive amounts", isOn: $flip).font(.footnote.weight(.semibold))
                }
                ForEach(out.warnings.prefix(3), id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.warn) }
                if out.warnings.count > 3 { Text("\(out.warnings.count - 3) more rows skipped.").font(.caption).foregroundStyle(Theme.warn) }
            }
        }
    }

    static func read(_ url: URL) throws -> (String, String) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5_000_000 else { throw ToolError(.invalidArguments, "Choose a statement smaller than 5 MB.") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ToolError(.invalidArguments, "This file isn’t readable text.")
        }
        return (url.lastPathComponent, text)
    }

    static func now() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    private static func day(_ ymd: String?) -> String { ymd.map { DemoStore.day("\($0)T12:00:00-07:00") } ?? "–" }
}

/// Merchant, date and signed amount for one transaction.
struct TransactionRow: View {
    let transaction: FWMCore.Transaction
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([DemoStore.day(transaction.postedAt), transaction.category, transaction.pending ? "Pending" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
            Spacer()
            Text(usd(transaction.signedAmountCents, cents: true, plus: true)).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(transaction.signedAmountCents > 0 ? Theme.ok : Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
