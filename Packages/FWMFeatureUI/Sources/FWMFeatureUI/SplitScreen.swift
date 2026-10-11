import SwiftUI
import FWMCore

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
private enum SplitDemo {
    static let transcript = "I paid for dinner with Tanish and Aryan. Split the appetizer evenly and divide tax and tip proportionally."
    static let misreadTipCents = 1_630, misreadConfidence = 0.58
}

/// Journey 3: receipt + voice → reviewed receipt → assignments → exact shares (SplitEngine) → requests → follow-ups.
struct SplitScreen: View {
    let store: DemoStore
    var onAction: (String) -> Void = { _ in }

    @State private var step = 0
    @State private var haveReceipt = false
    @State private var haveVoice = false
    @State private var tipText = String(format: "%.2f", Double(SplitDemo.misreadTipCents) / 100)
    @State private var owners: [String: String] = [:] // item → contact id or "shared"
    @State private var states: [String: RequestState] = [:]
    @State private var reminders: Set<String> = []
    @State private var disputed: Set<String> = []
    @State private var tomorrow = false
    @State private var reviewing: ReimbursementDraft?
    @State private var remindTarget: ReimbursementDraft?

    private static let steps = ["Inputs", "Check", "Assign", "Shares", "Requests", "Follow-ups"]
    private var receipt: Receipt? { store.dataset.receipts?.first }
    private var payerId: String { store.splitExample?.payerId ?? "c_ashwin" }
    private var tipCents: Int? { Decimal(string: tipText).map { NSDecimalNumber(decimal: $0 * 100).intValue } }

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
                                                         datasetVersion: store.dataset.datasetVersion, dataMode: store.dataset.dataMode))
        } catch let e as ToolError { return .failure(e) } catch { return .failure(ToolError(.invalidArguments, error.localizedDescription)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) { ForEach(0..<Self.steps.count, id: \.self) { i in Capsule().fill(i <= step ? Theme.accent : Theme.line).frame(height: 4) } }
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
            .background(Theme.bg)
            .navigationTitle("Split")
            .toolbar { DemoDataBadge() }
            .onAppear { if owners.isEmpty { resetOwners() } }
            .sheet(item: $reviewing) { q in reviewSheet(q) }
            .sheet(item: $remindTarget) { q in reminderSheet(q) }
        }
    }

    private func resetOwners() {
        owners = (store.splitExample?.assignments ?? [:]).mapValues { $0.count > 1 ? "shared" : ($0.first ?? "") }
    }

    private func nav(_ label: String, enabled: Bool = true) -> some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 }.buttonStyle(GhostButtonStyle()) }
            Button(label) { step += 1 }.buttonStyle(PrimaryButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
        .padding(.top, 8)
    }

    // MARK: steps

    @ViewBuilder private var inputs: some View {
        Text("Split dinner").font(Theme.display(30))
        Text("Send a receipt and a voice note to Lana in Messages, or add them here.").foregroundStyle(Theme.ink2)
        Card {
            HStack { Text("Receipt").font(.headline); Spacer(); Tag(text: haveReceipt ? "Received" : "Waiting", tone: haveReceipt ? Theme.accent : Theme.ink2, fill: haveReceipt ? Theme.accentSoft : Theme.line) }
            if haveReceipt, let r = receipt { Text("\(r.merchant ?? "Receipt") · \(r.date ?? "")").font(.caption).foregroundStyle(Theme.ink3) }
            Button("Use sample receipt") { haveReceipt = true }.buttonStyle(GhostButtonStyle())
        }
        Card {
            HStack { Text("Voice note").font(.headline); Spacer(); Tag(text: haveVoice ? "Transcribed" : "Waiting", tone: haveVoice ? Theme.accent : Theme.ink2, fill: haveVoice ? Theme.accentSoft : Theme.line) }
            if haveVoice {
                Text("“\(SplitDemo.transcript)”")
                SimulatedNote("Sample transcript. On iPhone, speech is transcribed on-device.")
            }
            Button("Use sample voice note") { haveVoice = true }.buttonStyle(GhostButtonStyle())
        }
        Card(padding: 14) {
            HStack { Text("Messages delivery").font(.subheadline); Spacer()
                Tag(text: haveReceipt && haveVoice ? "Completed · 2 of 2" : (haveReceipt || haveVoice ? "Pending · 1 of 2" : "Waiting")) }
            SimulatedNote("Simulated delivery states. The messaging line isn’t connected here.")
        }
        nav("Read receipt", enabled: haveReceipt && haveVoice)
    }

    @ViewBuilder private var check: some View {
        let res = result()
        let mismatch: Bool = { if case .failure(let e) = res, e.code == .receiptMismatch { return true }; return tipCents == nil }()
        let fixed = tipCents == receipt?.tipCents
        Text("Check what Lana read").font(Theme.display(30))
        Text(mismatch ? "One field looks off. Fix it before anything is sent." : "Everything adds up to the receipt total.").foregroundStyle(Theme.ink2)
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
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityLabel("Tip amount")
                }
                Divider()
                HStack { Text("Receipt total").bold(); Spacer(); Text(usd(r.totalCents, cents: true)).bold().monospacedDigit() }
                if mismatch {
                    Label("Doesn’t match the total yet. Requests stay blocked until it does.", systemImage: "xmark.circle").font(.caption.weight(.semibold)).foregroundStyle(Theme.bad)
                } else {
                    Label("Items, tax and tip match the total", systemImage: "checkmark.circle").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                SimulatedNote("The low-confidence tip is staged to show the correction step.")
            }
        }
        nav("Assign items", enabled: !mismatch)
    }

    @ViewBuilder private var assign: some View {
        Text("Who had what").font(Theme.display(30))
        Text("Filled in from your voice note. Tap to change.").foregroundStyle(Theme.ink2)
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
        Text("You’re owed \(usd(r.outstandingCents, cents: true))").font(Theme.display(30))
        Text("The appetizer is split evenly. Tax and tip follow what each person ordered.").foregroundStyle(Theme.ink2)
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
        Label("\(ordered.map { usd($0.totalCents, cents: true) }.joined(separator: " + ")) = \(usd(total, cents: true)), the receipt total.", systemImage: "checkmark")
            .font(.subheadline).monospacedDigit().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
        Text("Dated Oct 11, so it isn’t added to September’s spending.").font(.caption).foregroundStyle(Theme.ink3)
        nav("Prepare requests", enabled: total == receipt?.totalCents)
    }

    private func ordered(_ r: SplitResult) -> [ReimbursementDraft] {
        participants.compactMap { p in r.requests.first { $0.contactId == p.contactId } }
    }
    private func state(_ id: String) -> RequestState { states[id] ?? .draft }

    @ViewBuilder private func requests(_ r: SplitResult) -> some View {
        Text("Payment requests").font(Theme.display(30))
        Text("Nothing is sent without your review. Opening Venmo isn’t the same as sending a request.").foregroundStyle(Theme.ink2)
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
        Text("Lana can’t see inside Venmo. “You sent it” and “Paid” are what you tell Lana.").font(.caption).foregroundStyle(Theme.ink3)
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
                    Text("You finish and send the request yourself in Venmo. Lana won’t know it was sent until you say so.").font(.footnote)
                    SimulatedNote("Demo build: Venmo isn’t opened. Approving records the handoff only.")
                }
                Section {
                    Button("Approve & hand off") {
                        if state(q.contactId) != .handedOff { // duplicate tap guard
                            states[q.contactId] = .handedOff
                            onAction("Request for \(q.reviewedName) · \(usd(q.amountCents, cents: true)) handed off to Venmo")
                        }
                        reviewing = nil
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationTitle("Request \(usd(q.amountCents, cents: true))")
            .toolbar { Button("Not now") { reviewing = nil } }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func followUps(_ r: SplitResult) -> some View {
        Text("Follow-ups").font(Theme.display(30))
        Text("Lana can remind people who haven’t paid. Each reminder needs your OK.").foregroundStyle(Theme.ink2)
        Card {
            HStack {
                VStack(alignment: .leading) { Text("Demo clock").font(.caption).foregroundStyle(Theme.ink3); Text(tomorrow ? "Mon, Oct 12 · 10:00 AM" : "Sun, Oct 11 · 8:40 PM").fontWeight(.semibold) }
                Spacer()
                Button(tomorrow ? "Back to today" : "Jump to tomorrow") { tomorrow.toggle() }.buttonStyle(GhostButtonStyle())
            }
            SimulatedNote("Simulated clock. Real time and security timeouts are unchanged.")
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
                        Tag(text: tomorrow ? "Reminder sent Oct 12, 10:00 AM" : "Reminder set · tomorrow 10:00 AM", tone: Theme.accent, fill: Theme.accentSoft)
                    } else {
                        Tag(text: "Unpaid", tone: Theme.warn, fill: Theme.warnSoft)
                    }
                }
                if reminders.contains(id) && tomorrow && !closed {
                    Text(reminderText(q)).font(.subheadline).padding(12).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                    SimulatedNote("Simulated send. The messaging line isn’t connected here.")
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
            Button("Start over") { step = 0; haveReceipt = false; haveVoice = false; tipText = String(format: "%.2f", Double(SplitDemo.misreadTipCents) / 100)
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
                    Text("Cancelled automatically if they pay or dispute it.").font(.footnote)
                }
                Section {
                    Button("Approve reminder") {
                        if !reminders.contains(q.contactId) { reminders.insert(q.contactId); onAction("Reminder to \(q.reviewedName) for tomorrow 10:00 AM") }
                        remindTarget = nil
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationTitle("Remind \(q.reviewedName)?")
            .toolbar { Button("Not now") { remindTarget = nil } }
        }
        .presentationDetents([.medium])
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
        if current == .cancelled { Tag(text: "Cancelled", tone: Theme.bg, fill: Theme.ink) }
        else {
            let order: [RequestState] = [.draft, .readyForReview, .handedOff, .userReportedRequested, .paidReported]
            let idx = order.firstIndex(of: current) ?? 0
            WrapLayout(spacing: 4) { ForEach(Array(order.enumerated()), id: \.offset) { i, s in chip(s, i, idx) } }
        }
    }
    private func chip(_ s: RequestState, _ i: Int, _ idx: Int) -> some View {
        Tag(text: s.label, tone: i == idx ? Theme.bg : (i < idx ? Theme.accent : Theme.ink3), fill: i == idx ? Theme.ink : (i < idx ? Theme.accentSoft : Theme.line))
    }
}
