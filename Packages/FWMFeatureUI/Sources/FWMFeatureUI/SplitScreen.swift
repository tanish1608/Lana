import SwiftUI
import FWMCore
import FinanceAI

/// Request lifecycle shown to the user. Payment states are what the user reports; there is no settlement feed.
enum RequestState: String, CaseIterable {
    case draft, readyForReview = "ready_for_review", handedOff = "handed_off", userReportedRequested = "user_reported_requested", paidReported = "paid_reported", cancelled
    var label: String {
        switch self {
        case .draft: return "Draft"
        case .readyForReview: return "Ready for review"
        case .handedOff: return "Handed off"
        case .userReportedRequested: return "You sent it"
        case .paidReported: return "Paid (you said)"
        case .cancelled: return "Cancelled"
        }
    }
}

// Demo inputs not in the fixture: a staged low-confidence tip read and a sample transcript.
enum SplitDemo {
    static let transcript = "I paid for dinner with Tanish and Aryan. Split the appetizer evenly and divide tax and tip proportionally."
    static let misreadTipCents = 1_630, misreadConfidence = 0.58
}

/// Journey 3: receipt + voice → reviewed receipt → assignments → exact shares (SplitEngine) → requests → follow-ups.
struct SplitScreen: View {
    let store: DemoStore
    var isActive = true
    @Environment(\.scenePhase) private var scenePhase
    var onReview: (Receipt, [String: [String]], String, SplitResult) -> Void = { _, _, _, _ in }
    var onInvalidate: () -> Void = {}
    var onAction: (String) -> Void = { _ in }

    @State private var step = 0
    @State private var keptAsMine = false
    @State private var importedReceipt: Receipt?
    @State private var importSheet = false
    @State private var transcript = ""
    @State private var transcriptStatus: String?
    #if os(iOS)
    @State private var voice = LocalVoiceInput()
    #endif
    @State private var haveReceipt = false
    @State private var haveVoice = false
    @State private var tipText = String(format: "%.2f", Double(SplitDemo.misreadTipCents) / 100)
    @State private var owners: [String: String] = [:] // item → contact id or "shared"
    @Binding var states: [String: RequestState] // held by the root so Home can show who still owes
    @State private var reminders: Set<String> = []
    @State private var disputed: Set<String> = []
    @State private var tomorrow = false
    @State private var reviewing: ReimbursementDraft?
    @State private var remindTarget: ReimbursementDraft?
    @FocusState private var tipFocused: Bool

    private static let steps = ["Receipt", "Check", "Assign", "Shares", "Requests", "Follow-ups"]
    private var receipt: Receipt? { importedReceipt ?? store.dataset.receipts?.first }
    private var payerId: String { store.splitExample?.payerId ?? "c_ashwin" }
    private var tipCents: Int? { try? ReceiptReviewAmounts.cents(tipText) }

    private var participants: [Contact] {
        let ids = Set([payerId] + (store.splitExample?.assignments.values.flatMap { $0 } ?? []))
        let list = (store.dataset.contacts ?? []).filter { ids.contains($0.contactId) }
        return list.filter { $0.contactId == payerId } + list.filter { $0.contactId != payerId }
    }
    private func name(_ id: String) -> String { store.dataset.contacts?.first { $0.contactId == id }?.reviewedName ?? id }

    private func result() -> Result<SplitResult, ToolError> {
        guard var r = receipt else { return .failure(ToolError(.invalidArguments, "No receipt yet.")) }
        r.tipCents = tipCents ?? -1
        let everyone = participants.map(\.contactId)
        let assignments = Dictionary(uniqueKeysWithValues: r.items.map { i in
            (i.itemId, owners[i.itemId] == "shared" ? everyone : [owners[i.itemId] ?? ""])
        })
        do {
            return .success(try SplitEngine.prepareSplit(receipt: r, assignments: assignments, payerId: payerId, contacts: store.dataset.contacts ?? [],
                                                         datasetVersion: store.dataset.datasetVersion, dataMode: r.receiptId.hasPrefix("local-") ? .cached : store.dataset.dataMode))
        } catch let e as ToolError { return .failure(e) } catch { return .failure(ToolError(.invalidArguments, error.localizedDescription)) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) { ForEach(0..<Self.steps.count, id: \.self) { i in Capsule().fill(i <= step ? Theme.accent : Theme.line).frame(height: 4) } }
                        .id("top")
                    if haveVoice { AskChip(SplitDemo.transcript, kind: .split, store: store) }
                    Text("Step \(step + 1) of \(Self.steps.count) · \(Self.steps[step])").font(.caption).foregroundStyle(Theme.ink3)
                    switch step {
                    case 0: inputs
                    case 1: check
                    case 2: assign
                    default: computed
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
                .animation(.easeOut(duration: 0.2), value: step)
            }
            // The cards grow as inputs arrive; bring the primary button back above the tab bar.
            .onChange(of: haveReceipt) { _, ready in if ready { withAnimation { proxy.scrollTo("nav", anchor: .bottom) } } }
            .onChange(of: step) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
            .scrollIndicators(.hidden).background { Theme.backdrop }
            .navigationTitle("Receipts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline) // each step has its own heading
            #endif
            .onAppear { if owners.isEmpty { resetOwners() } }
            .onChange(of: owners) { _, _ in onInvalidate() }
            .onChange(of: tipText) { _, _ in onInvalidate() }
            .sheet(isPresented: $importSheet) {
                if let template = receipt {
                    ReceiptImportSheet(template: template) { r in
                        importedReceipt = r; haveReceipt = true
                        tipText = String(format: "%.2f", Double(r.tipCents) / 100)
                        resetOwners(); states = [:]; reminders = []; disputed = []; step = 1
                        onInvalidate()
                    }
                }
            }
            #if os(iOS)
            .onDisappear { voice.cancel() }
            .onChange(of: isActive) { _, active in if !active { voice.cancel() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { voice.cancel() } }
            #endif
            .sheet(item: $reviewing) { q in reviewSheet(q) }
            .sheet(item: $remindTarget) { q in reminderSheet(q) }
        }
    }

    private func resetOwners() {
        if let importedReceipt {
            owners = Dictionary(uniqueKeysWithValues: importedReceipt.items.map { ($0.itemId, "") })
            return
        }
        owners = (store.splitExample?.assignments ?? [:]).mapValues { $0.count > 1 ? "shared" : ($0.first ?? "") }
    }

    private func nav(_ label: String, enabled: Bool = true) -> some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 }.buttonStyle(GhostButtonStyle()) }
            Button(label) {
                if step == 2, case .success(let value) = result(), var reviewed = receipt {
                    reviewed.tipCents = tipCents ?? -1
                    let assignments = Dictionary(uniqueKeysWithValues: reviewed.items.map { item in
                        (item.itemId, owners[item.itemId] == "shared" ? participants.map(\.contactId) : [owners[item.itemId] ?? ""])
                    })
                    onReview(reviewed, assignments, payerId, value)
                }
                step += 1
            }.buttonStyle(PrimaryButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
        .padding(.top, 8).padding(.bottom, 12)
        .id("nav")
    }

    private func option(_ icon: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 40, height: 40)
                    .background(Theme.deepBlueFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) { Text(title).fontWeight(.semibold); Text(sub).font(.caption).foregroundStyle(Theme.ink2) }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3)
            }
            .foregroundStyle(Theme.ink).padding(14)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).raised(18)
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: steps

    @ViewBuilder private var inputs: some View {
        Text("Add a receipt").font(Theme.display(30))
        Text("Any receipt. Lana reads it, then you choose what to do.").font(.subheadline).foregroundStyle(Theme.ink2)
        Card {
            HStack { Text("Receipt").font(.headline); Spacer(); Tag(text: haveReceipt ? "Received" : "Waiting", tone: haveReceipt ? Theme.accent : Theme.ink2, fill: haveReceipt ? Theme.accentSoft : Theme.line) }
            if haveReceipt, let r = receipt { Text("\(r.merchant ?? "Receipt") · \(r.date ?? "")").font(.caption).foregroundStyle(Theme.ink3) }
            Button("Import receipt image") { importSheet = true }.buttonStyle(GhostButtonStyle())
            Button("Use sample receipt") { importedReceipt = nil; haveReceipt = true; resetOwners(); tipText = String(format: "%.2f", Double(SplitDemo.misreadTipCents) / 100); onInvalidate() }.buttonStyle(GhostButtonStyle())
        }
        Card {
            HStack { Text("Tell Lana what to do").font(.headline); Spacer(); Tag(text: haveVoice ? "Transcribed" : "Optional", tone: haveVoice ? Theme.accent : Theme.ink2, fill: haveVoice ? Theme.accentSoft : Theme.line) }
            if haveVoice {
                TextField("Review transcript", text: $transcript, axis: .vertical).lineLimit(2...6)
            }
            #if os(iOS)
            Button(voice.recording ? "Stop & transcribe" : "Record voice note") {
                Task {
                    if voice.recording {
                        if let text = await voice.finish() { transcript = text; haveVoice = true }
                    } else { await voice.start() }
                    transcriptStatus = voice.status
                }
            }.buttonStyle(GhostButtonStyle()).disabled(voice.busy)
            #endif
            if let transcriptStatus { Text(transcriptStatus).font(.caption).foregroundStyle(Theme.ink3) }
            Button("Use sample voice note") { haveVoice = true; transcript = SplitDemo.transcript; transcriptStatus = "Sample transcript. Review assignments yourself below." }.buttonStyle(GhostButtonStyle())
        }
        Card(padding: 14) {
            HStack { Text("Messages delivery").font(.subheadline); Spacer()
                Tag(text: haveReceipt ? (haveVoice ? "Receipt + voice note" : "Receipt received") : "Waiting") }
            SimulatedNote("Simulated")
        }
        nav("Read receipt", enabled: haveReceipt)
    }

    @ViewBuilder private var check: some View {
        let res = result()
        let mismatch: Bool = { if case .failure(let e) = res, e.code == .receiptMismatch { return true }; return tipCents == nil }()
        let fixed = tipCents == receipt?.tipCents
        Text("Check what Lana read").font(Theme.display(30))
        if let r = receipt {
            Card {
                ForEach(r.items, id: \.itemId) { i in
                    HStack { Text(i.description); Spacer(); Text(usd(i.extendedPriceCents, cents: true)).monospacedDigit() }
                }
                HStack { Text("Tax"); Spacer(); Text(usd(r.taxCents, cents: true)).monospacedDigit() }
                HStack {
                    Text("Tip")
                    if fixed { Tag(text: "Corrected", tone: Theme.accent, fill: Theme.accentSoft) }
                    else { Tag(text: "Unsure · \(Int((SplitDemo.misreadConfidence * 100).rounded()))%", tone: Theme.warn, fill: Theme.warnSoft) }
                    Spacer()
                    TextField("Tip", text: $tipText).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 90)
                        .padding(8).background(fixed ? Theme.card : Theme.warnSoft, in: RoundedRectangle(cornerRadius: 10))
                        .focused($tipFocused)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        // Select the misread value on focus so typing replaces it (the decimal pad has no quick way to clear).
                        .onChange(of: tipFocused) { _, focused in
                            if focused { DispatchQueue.main.async { UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil) } }
                        }
                        #endif
                        .accessibilityLabel("Tip amount")
                }
                Divider()
                HStack { Text("Receipt total").bold(); Spacer(); Text(usd(r.totalCents, cents: true)).bold().monospacedDigit() }
                if mismatch {
                    Label("Doesn’t match the total yet", systemImage: "xmark.circle").font(.caption.weight(.semibold)).foregroundStyle(Theme.bad)
                } else {
                    Label("Items, tax and tip match the total", systemImage: "checkmark.circle").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                SimulatedNote("Staged misread")
            }
        }
        SectionLabel("What should Lana do with it?")
        VStack(spacing: 10) {
            option("person.2.fill", "Split it with people", "Assign items and get exact shares") { keptAsMine = false; step = 2 }
            option("person.fill", "One person owes it all", "Request the full amount from someone") {
                keptAsMine = false
                if let friend = participants.first(where: { $0.contactId != payerId }), let r = receipt {
                    owners = Dictionary(uniqueKeysWithValues: r.items.map { ($0.itemId, friend.contactId) })
                }
                step = 2
            }
            option("tray.and.arrow.down.fill", "It’s just mine", "Keep the receipt, no one owes you") { withAnimation { keptAsMine = true } }
        }
        .disabled(mismatch).opacity(mismatch ? 0.45 : 1)
        if keptAsMine, let r = receipt {
            Card {
                Label("Kept in your receipts", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Theme.ok)
                Text("\(r.merchant ?? "Receipt") · \(usd(r.totalCents, cents: true)). Dated \(r.date ?? "after September"), so it isn’t added to September’s spending.")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                SimulatedNote("Simulated. Not saved to your records in this build.")
            }
        }
        Button("Back") { step -= 1 }.buttonStyle(GhostButtonStyle()).padding(.top, 4).padding(.bottom, 12).id("nav")
    }

    @ViewBuilder private var assign: some View {
        Text("Who had what").font(Theme.display(30))
        SectionLabel("People")
        Card {
            ForEach(participants, id: \.contactId) { c in
                HStack {
                    Avatar(name: c.reviewedName)
                    VStack(alignment: .leading) {
                        Text(c.reviewedName + (c.isSelf == true ? " (you)" : "")).fontWeight(.semibold)
                        Text(c.contactId == payerId ? "Paid the bill" : "\(c.venmoHandle ?? "") · \(c.phone)").font(.caption).foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                    if c.isSelf != true { Tag(text: "Reviewed", tone: Theme.accent, fill: Theme.accentSoft) }
                }
            }
        }
        SectionLabel("Items")
        if let r = receipt {
            ForEach(r.items, id: \.itemId) { i in
                Card(padding: 14) {
                    HStack { Text(i.description).fontWeight(.semibold); Spacer(); Text(usd(i.extendedPriceCents, cents: true)).monospacedDigit() }
                    Picker(i.description, selection: Binding(get: { owners[i.itemId] ?? "" }, set: { owners[i.itemId] = $0 })) {
                        ForEach(participants, id: \.contactId) { Text($0.reviewedName).tag($0.contactId) }
                        Text("Shared").tag("shared")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        nav("Calculate shares")
    }

    @ViewBuilder private var computed: some View {
        switch result() {
        case .failure(let e):
            Card { Tag(text: "Needs a fix", tone: Theme.bad); Text(e.userMessage) }
            Button("Back") { step = 2 }.buttonStyle(GhostButtonStyle())
        case .success(let r):
            if step == 3 { shares(r) } else if step == 4 { requests(r) } else { followUps(r) }
        }
    }

    @ViewBuilder private func shares(_ r: SplitResult) -> some View {
        let ordered = participants.compactMap { p in r.shares.first { $0.contactId == p.contactId } }
        let total = r.shares.reduce(0) { $0 + $1.totalCents }
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("You’re owed")
            HeroAmount(cents: r.outstandingCents)
        }
        .padding(.horizontal, 4)
        ForEach(ordered, id: \.contactId) { s in
            Card(padding: 16) {
                HStack {
                    Avatar(name: name(s.contactId))
                    VStack(alignment: .leading) {
                        Text(name(s.contactId)).fontWeight(.semibold)
                        Text("\(usd(s.itemsCents, cents: true)) food + \(usd(s.taxTipCents, cents: true)) tax & tip").font(.caption).foregroundStyle(Theme.ink3).monospacedDigit()
                    }
                    Spacer()
                    Text(usd(s.totalCents, cents: true)).font(Theme.display(24)).monospacedDigit()
                }
                if s.contactId == payerId { Text("Your share. You paid the bill.").font(.caption).foregroundStyle(Theme.ink3) }
            }
        }
        CheckLine("\(ordered.map { usd($0.totalCents, cents: true) }.joined(separator: " + ")) = \(usd(total, cents: true))")
        Text("Oct 11 · not in September’s spending").font(.caption).foregroundStyle(Theme.ink3).padding(.horizontal, 4)
        nav("Prepare requests", enabled: total == receipt?.totalCents)
    }

    private func ordered(_ r: SplitResult) -> [ReimbursementDraft] {
        participants.compactMap { p in r.requests.first { $0.contactId == p.contactId } }
    }
    private func state(_ id: String) -> RequestState { states[id] ?? .draft }

    @ViewBuilder private func requests(_ r: SplitResult) -> some View {
        Text("Payment requests").font(Theme.display(30))
        ForEach(ordered(r), id: \.contactId) { q in
            Card(padding: 16) {
                HStack { Avatar(name: q.reviewedName); VStack(alignment: .leading) { Text(q.reviewedName).fontWeight(.semibold); Text(q.venmoHandle ?? "").font(.caption).foregroundStyle(Theme.ink3) }
                    Spacer(); Text(usd(q.amountCents, cents: true)).font(.title3.weight(.bold)).monospacedDigit() }
                StateTrack(current: state(q.contactId))
                HStack {
                    switch state(q.contactId) {
                    case .draft, .readyForReview:
                        Button("Review request") { if state(q.contactId) == .draft { states[q.contactId] = .readyForReview }; reviewing = q }.buttonStyle(GhostButtonStyle())
                    case .handedOff:
                        Button("I sent it in Venmo") { states[q.contactId] = .userReportedRequested; onAction("\(q.reviewedName): you reported the request as sent") }.buttonStyle(GhostButtonStyle())
                        Button("Cancel") { cancel(q) }.buttonStyle(GhostButtonStyle())
                    case .userReportedRequested:
                        Button("Mark paid") { markPaid(q) }.buttonStyle(GhostButtonStyle())
                        Button("Cancel") { cancel(q) }.buttonStyle(GhostButtonStyle())
                    case .paidReported: Tag(text: "Paid, as you reported", tone: Theme.accent, fill: Theme.accentSoft)
                    case .cancelled: Button("Reopen draft") { states[q.contactId] = .draft }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
        Text("“Sent” and “Paid” are what you tell Lana.").font(.caption).foregroundStyle(Theme.ink3).padding(.horizontal, 4)
        nav("Set up follow-ups")
    }

    private func cancel(_ q: ReimbursementDraft) {
        states[q.contactId] = .cancelled
        if reminders.contains(q.contactId) { onAction("Reminder to \(q.reviewedName) cancelled") }
    }
    private func markPaid(_ q: ReimbursementDraft) {
        guard state(q.contactId) != .paidReported else { return }
        states[q.contactId] = .paidReported
        onAction("\(q.reviewedName) paid, as you reported")
        if reminders.contains(q.contactId) { onAction("Reminder to \(q.reviewedName) cancelled (paid)") }
    }

    private func reviewSheet(_ q: ReimbursementDraft) -> some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To", value: "\(q.reviewedName) · \(q.venmoHandle ?? "")")
                    LabeledContent("Amount", value: usd(q.amountCents, cents: true))
                    LabeledContent("Note", value: q.note)
                    LabeledContent("How", value: "Open Venmo with details filled in")
                }
                Section {
                    Text("You send it yourself in Venmo.").font(.footnote)
                    SimulatedNote("Simulated. Venmo isn’t opened.")
                }
                Section {
                    Button("Approve & hand off") {
                        if state(q.contactId) != .handedOff { // duplicate tap guard
                            states[q.contactId] = .handedOff
                            onAction("Simulated Venmo handoff for \(q.reviewedName) · \(usd(q.amountCents, cents: true)); nothing sent")
                        }
                        reviewing = nil
                    }
                    .buttonStyle(PrimaryButtonStyle()).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Request \(usd(q.amountCents, cents: true))")
            .toolbar { Button("Not now") { reviewing = nil } }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func followUps(_ r: SplitResult) -> some View {
        Text("Follow-ups").font(Theme.display(30))
        Card {
            let clock = VStack(alignment: .leading, spacing: 4) { SimulatedNote("Demo clock"); Text(tomorrow ? "Mon, Oct 12 · 10:00 AM" : "Sun, Oct 11 · 8:40 PM").fontWeight(.semibold).fixedSize() }
            let jump = Button(tomorrow ? "Back to today" : "Jump to tomorrow") { tomorrow.toggle() }.buttonStyle(GhostButtonStyle())
            ViewThatFits(in: .horizontal) { // date stays on one line; the button drops below when they don't fit side by side
                HStack { clock; Spacer(); jump }
                VStack(alignment: .leading, spacing: 10) { clock; jump }
            }
        }
        ForEach(ordered(r), id: \.contactId) { q in
            let id = q.contactId, s = state(id), closed = s == .paidReported || s == .cancelled || disputed.contains(id)
            Card(padding: 16) {
                HStack { Avatar(name: q.reviewedName); Text("\(q.reviewedName) owes \(usd(q.amountCents, cents: true))").fontWeight(.semibold); Spacer() }
                HStack {
                    if closed {
                        Tag(text: reminders.contains(id) ? "Reminder cancelled" : "No reminder needed")
                        if s == .paidReported { Tag(text: "Paid (you said)", tone: Theme.accent, fill: Theme.accentSoft) }
                        if disputed.contains(id) { Tag(text: "Disputed", tone: Theme.bad) }
                    } else if reminders.contains(id) {
                        Tag(text: tomorrow ? "Simulated reminder · Oct 12, 10:00 AM" : "Demo reminder set · tomorrow 10:00 AM", tone: Theme.accent, fill: Theme.accentSoft)
                    } else {
                        Tag(text: "Unpaid", tone: Theme.warn, fill: Theme.warnSoft)
                    }
                }
                if reminders.contains(id) && tomorrow && !closed {
                    Text(reminderText(q)).font(.subheadline).padding(12).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                    SimulatedNote("Simulated")
                }
                HStack {
                    if !closed && !reminders.contains(id) { Button("Approve reminder") { remindTarget = q }.buttonStyle(GhostButtonStyle()) }
                    if !closed && reminders.contains(id) { Button("Mark paid") { markPaid(q) }.buttonStyle(GhostButtonStyle()) }
                    if !closed {
                        Button("They disputed it") {
                            disputed.insert(id)
                            if reminders.contains(id) { onAction("Reminder to \(q.reviewedName) cancelled (disputed)") }
                        }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
        HStack {
            Button("Back") { step -= 1 }.buttonStyle(GhostButtonStyle())
            Button("Start over") { step = 0; keptAsMine = false; haveReceipt = false; haveVoice = false; tipText = String(format: "%.2f", Double(SplitDemo.misreadTipCents) / 100)
                states = [:]; reminders = []; disputed = []; tomorrow = false; resetOwners() }.buttonStyle(GhostButtonStyle())
        }
    }

    private func reminderText(_ q: ReimbursementDraft) -> String {
        "Hey \(q.reviewedName), quick reminder: your share of dinner at \(receipt?.merchant ?? "dinner") was \(usd(q.amountCents, cents: true)). Thanks!"
    }

    private func reminderSheet(_ q: ReimbursementDraft) -> some View {
        NavigationStack {
            Form {
                Section("Message") { Text(reminderText(q)) }
                Section {
                    LabeledContent("To", value: store.dataset.contacts?.first { $0.contactId == q.contactId }?.phone ?? "")
                    LabeledContent("Channel", value: "Messages")
                    LabeledContent("When", value: "Once, tomorrow 10:00 AM")
                    Text("Cancelled if they pay or dispute.").font(.footnote)
                }
                Section {
                    Button("Approve reminder") {
                        if !reminders.contains(q.contactId) { reminders.insert(q.contactId); onAction("Reminder to \(q.reviewedName) for tomorrow 10:00 AM") }
                        remindTarget = nil
                    }
                    .buttonStyle(PrimaryButtonStyle()).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Remind \(q.reviewedName)?")
            .toolbar { Button("Not now") { remindTarget = nil } }
        }
        .presentationDetents([.large])
    }
}

extension ReimbursementDraft: Identifiable { public var id: String { contactId } }

struct Avatar: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1))).font(.subheadline.weight(.bold)).frame(width: 36, height: 36)
            .foregroundStyle(Theme.ink2).background(Theme.line, in: Circle())
    }
}

struct StateTrack: View {
    let current: RequestState
    var body: some View {
        if current == .cancelled { Tag(text: "Cancelled", tone: Theme.ink2, fill: Theme.line) }
        else {
            let order: [RequestState] = [.draft, .readyForReview, .handedOff, .userReportedRequested, .paidReported]
            let idx = order.firstIndex(of: current) ?? 0
            WrapLayout(spacing: 4) { ForEach(Array(order.enumerated()), id: \.offset) { i, s in chip(s, i, idx) } }
        }
    }
    private func chip(_ s: RequestState, _ i: Int, _ idx: Int) -> some View {
        Tag(text: s.label, tone: i == idx ? .white : (i < idx ? Theme.accent : Theme.ink3), fill: i == idx ? Theme.accent : (i < idx ? Theme.accentSoft : Theme.line))
    }
}
