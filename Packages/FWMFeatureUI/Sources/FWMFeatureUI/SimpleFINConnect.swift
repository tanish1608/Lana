import SwiftUI
import FWMCore

/// Live connection through SimpleFIN Bridge: paste a setup token (or use SimpleFIN's demo bank), review the accounts
/// SimpleFIN returns, choose which to add. The phone talks to SimpleFIN directly; nothing goes through the relay.
struct SimpleFINConnectView: View {
    let institution: Institution?
    let user: UserPrefs
    /// Chosen accounts and their transactions, plus the access URL and a label so the connection can be saved for refresh.
    var onAdd: ([Account], [FWMCore.Transaction], URL, String) -> Void
    @State private var token = ""
    @State private var loading = false
    @State private var error: String?
    @State private var result: (source: String, data: SimpleFIN.Normalized)?
    @State private var accessURL: URL?
    @State private var chosen: Set<String> = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    LanaOrb(size: 52)
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.ink3).frame(width: 5, height: 5) } }
                    if let institution { InstitutionLogo(name: institution.name, size: 56) }
                    else { Image(systemName: "building.columns.fill").font(.title2).foregroundStyle(.white).frame(width: 56, height: 56)
                        .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous)) }
                }
                .frame(maxWidth: .infinity).padding(.top, 8)
                VStack(spacing: 6) {
                    Text(institution.map { "Link \($0.name)" } ?? "Link a bank").font(Theme.display(26))
                    Text("Through SimpleFIN Bridge, a read-only bank connection service.").foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                if let result { review(result) } else { connect }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden).background { Theme.backdrop }
        .navigationTitle("SimpleFIN")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private var connect: some View {
        SectionLabel("Your bank")
        Card {
            Text("1. At SimpleFIN Bridge, connect \(institution?.name ?? "your bank") and create a setup token.\n2. Paste the token here. Lana claims it once and reads the last 90 days.")
                .font(.subheadline).foregroundStyle(Theme.ink2)
            TextField("Setup token", text: $token, axis: .vertical).lineLimit(1...3).font(.system(.footnote, design: .monospaced))
                .padding(10).background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            Button(loading ? "Connecting…" : "Connect") { let setup = token; run("your SimpleFIN connection") { try await SimpleFIN.claim(setupToken: setup) } }
                .buttonStyle(PrimaryButtonStyle(fill: institution?.color ?? Theme.accent))
                .disabled(loading || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        SectionLabel("Just trying it?")
        Card {
            Text("SimpleFIN runs a demo bank on its real API. Lana reads it exactly as it would read yours.").font(.subheadline).foregroundStyle(Theme.ink2)
            Button(loading ? "Connecting…" : "Use SimpleFIN’s demo bank") { run("SimpleFIN’s demo bank") { SimpleFIN.demoAccessURL } }
                .buttonStyle(GhostButtonStyle()).disabled(loading)
        }
        if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 4) }
        Text("Lana can read balances and transactions. It can’t move money, and your bank password stays with SimpleFIN.")
            .font(.caption).foregroundStyle(Theme.ink3).padding(.horizontal, 4)
    }

    @ViewBuilder private func review(_ r: (source: String, data: SimpleFIN.Normalized)) -> some View {
        SectionLabel("Found at \(r.source)")
        VStack(spacing: 0) {
            ForEach(Array(r.data.accounts.enumerated()), id: \.element.accountId) { n, a in
                if n > 0 { Divider().padding(.leading, 62) }
                let count = r.data.transactions.filter { $0.accountId == a.accountId }.count
                Button { if chosen.contains(a.accountId) { chosen.remove(a.accountId) } else { chosen.insert(a.accountId) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: chosen.contains(a.accountId) ? "checkmark.circle.fill" : "circle").font(.title3)
                            .foregroundStyle(chosen.contains(a.accountId) ? Theme.accent : Theme.ink3)
                        InstitutionLogo(name: a.institution, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(a.institution) \(AccountKind.name(a.kind))").fontWeight(.semibold).foregroundStyle(Theme.ink)
                            Text("\(count) transaction\(count == 1 ? "" : "s") in 90 days").font(.caption).foregroundStyle(Theme.ink2)
                        }
                        Spacer()
                        Text(usd(a.balanceCents, cents: true)).fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).raised(20)
        ForEach(r.data.warnings.prefix(3), id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.warn) }
        Button("Add \(chosen.count) account\(chosen.count == 1 ? "" : "s")") {
            let accounts = r.data.accounts.filter { chosen.contains($0.accountId) }
            guard let accessURL else { return }
            onAdd(accounts, r.data.transactions.filter { chosen.contains($0.accountId) }, accessURL, Set(accounts.map(\.institution)).sorted().joined(separator: ", ") + " via SimpleFIN")
        }
        .buttonStyle(PrimaryButtonStyle()).disabled(chosen.isEmpty).padding(.top, 6)
        Button("Start over") { result = nil; chosen = [] }.buttonStyle(GhostButtonStyle())
    }

    /// Resolves an access URL (claiming a token if needed), reads 90 days, normalizes. Errors stay on screen.
    private func run(_ source: String, access: @escaping @Sendable () async throws -> URL) {
        loading = true; error = nil
        let user = self.user
        task = Task {
            defer { loading = false }
            do {
                let url = try await access()
                accessURL = url
                let set = try await SimpleFIN.fetch(accessURL: url, since: Date().addingTimeInterval(-90 * 86_400))
                try Task.checkCancellation()
                let data = SimpleFIN.normalize(set, user: user, asOf: StatementImportView.now())
                guard !data.accounts.isEmpty else { throw ToolError(.providerUnavailable, "SimpleFIN returned no USD accounts for this connection.") }
                result = (source, data)
                chosen = Set(data.accounts.filter { a in a.balanceCents != 0 || data.transactions.contains { $0.accountId == a.accountId } }.map(\.accountId))
            } catch is CancellationError {
            } catch { self.error = (error as? ToolError)?.userMessage ?? error.localizedDescription }
        }
    }
}
