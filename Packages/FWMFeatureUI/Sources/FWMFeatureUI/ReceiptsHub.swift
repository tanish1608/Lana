import SwiftUI
import FWMCore

// PREVIEW STAND-IN: two labelled sample receipts so the Receipts tab can show more than the dinner fixture
// (seed-v1 has one receipt). Mirrors P.receipts in preview/web/preview-data.js. Not fixture data.
struct SampleReceipt: Identifiable, Equatable {
    enum Kind { case bill, store }
    let id: String, kind: Kind, merchant: String, date: String, category: String, totalCents: Int
    var due: String?, paidWith: String?
    let lines: [Line]
    struct Line: Equatable, Identifiable { let text: String; let cents: Int; var id: String { text } }
    var icon: String { kind == .bill ? "bolt.fill" : "cart.fill" }
}

enum PreviewReceipts {
    static let all = [
        SampleReceipt(id: "rcpt_power_1009", kind: .bill, merchant: "Demo Power & Light", date: "Oct 9", category: "Bills and subscriptions", totalCents: 8_412, due: "Oct 20",
                      lines: [.init(text: "Electricity, Sep 1–30", cents: 7_130), .init(text: "Delivery charge", cents: 900), .init(text: "Taxes and fees", cents: 382)]),
        SampleReceipt(id: "rcpt_market_1010", kind: .store, merchant: "Demo Market", date: "Oct 10", category: "Groceries", totalCents: 6_347, paidWith: "Demo Card",
                      lines: [.init(text: "Produce", cents: 1_890), .init(text: "Oat milk ×2", cents: 998), .init(text: "Pasta, rice, beans", cents: 1_642), .init(text: "Coffee beans", cents: 1_399), .init(text: "Tax", cents: 418)]),
    ]
}

/// What Lana can do with a receipt. Every action is confirmed first and, in this build, simulated.
enum ReceiptAction: String, Identifiable {
    case split, pay, budget, remind, keep
    var id: String { rawValue }
    var title: String {
        switch self { case .split: return "Split it"; case .pay: return "Pay it"; case .budget: return "Add to budget"; case .remind: return "Remind me"; case .keep: return "Keep for returns" }
    }
    var icon: String {
        switch self { case .split: return "person.2.fill"; case .pay: return "creditcard.fill"; case .budget: return "chart.pie.fill"; case .remind: return "bell.fill"; case .keep: return "arrow.uturn.backward.circle.fill" }
    }
}

struct ReceiptActionRequest: Identifiable { let receipt: SampleReceipt; let action: ReceiptAction; var id: String { receipt.id + action.rawValue } }

/// Detail for a sample receipt: what it is, then a 2×2 of things Lana can do.
struct SampleReceiptDetail: View {
    let receipt: SampleReceipt
    let status: String?
    let people: [String]
    var onBack: () -> Void
    var onConfirm: (ReceiptAction, String, String) -> Void // action, status shown on the receipt, approvals log line
    @State private var asking: ReceiptActionRequest?

    private var actions: [ReceiptAction] { [.split, .pay, .budget, receipt.kind == .bill ? .remind : .keep] }
    private func subtitle(_ a: ReceiptAction) -> String {
        switch a {
        case .split: return "Evenly, \(people.count) ways"
        case .pay: return receipt.paidWith.map { "Already paid · \($0)" } ?? "From Checking"
        case .budget: return receipt.category.replacingOccurrences(of: " and subscriptions", with: " & subs")
        case .remind: return "Before \(receipt.due ?? "it’s due")"
        case .keep: return "30-day return window"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) { Label("Receipts", systemImage: "chevron.left").font(.subheadline.weight(.semibold)) }.frame(minHeight: 36)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Eyebrow("\(receipt.date) · \(receipt.lines.count) lines"); Spacer(); Tag(text: "Sample", tone: Theme.warn, fill: Theme.warnSoft) }
                Text(receipt.merchant).font(.title2.bold())
                HeroAmount(cents: receipt.totalCents, size: 44)
                if let due = receipt.due { Text("Due \(due)").font(.footnote.weight(.semibold)).foregroundStyle(Theme.warn) }
                Divider()
                ForEach(receipt.lines) { l in
                    HStack { Text(l.text); Spacer(); Text(usd(l.cents, cents: true)).monospacedDigit() }.font(.subheadline)
                }
                if let status { Label(status, systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ok).padding(.top, 2) }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).raised(24)
            SectionLabel("What should Lana do?")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(actions) { a in
                    let off = a == .pay && receipt.paidWith != nil
                    Button { asking = ReceiptActionRequest(receipt: receipt, action: a) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: a.icon).font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 40, height: 40)
                                .background(Theme.deepBlueFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(a.title).fontWeight(.semibold)
                            Text(subtitle(a)).font(.caption).foregroundStyle(Theme.ink2).lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(Theme.ink).padding(14).frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).raised(18)
                        .opacity(off ? 0.5 : 1)
                    }
                    .buttonStyle(PressScaleStyle()).disabled(off)
                }
            }
        }
        .sheet(item: $asking) { confirm($0) }
    }

    private func confirm(_ r: ReceiptActionRequest) -> some View {
        let shares = SplitEngine.allocate(receipt.totalCents, weights: people.map { _ in 1 })
        let total = usd(receipt.totalCents, cents: true)
        let copy: (title: String, detail: String, button: String, status: String, guardrail: String) = {
            switch r.action {
            case .split:
                let others = zip(people, shares).dropFirst().map { "\($0) \(usd($1, cents: true))" }.joined(separator: ", ")
                return ("Split it evenly?", "\(total) across \(people.count) people. You’d ask for: \(others).", "Draft requests", "Split \(people.count) ways · requests drafted", "You review each request before anything is sent.")
            case .pay: return ("Pay this bill?", "\(total) to \(receipt.merchant) from Checking\(receipt.due.map { ", before it’s due \($0)" } ?? "").", "Pay \(total)", "Payment approved · \(total)", "Only this one payment, and only because you approve it here.")
            case .budget: return ("Add to your budget?", "File \(total) under \(receipt.category) for October.", "Add to \(receipt.category.components(separatedBy: " ").first ?? "budget")", "Filed under \(receipt.category)", "This changes your budget view only. No money moves.")
            case .remind: return ("Remind you?", "A nudge in Messages two days before \(receipt.due ?? "it’s due").", "Remind me", "Reminder set before \(receipt.due ?? "due date")", "One reminder. Cancelled if you pay first.")
            case .keep: return ("Keep for returns?", "Hold this receipt for 30 days in case you return something.", "Keep it", "Kept for returns · 30 days", "Nothing is sent anywhere.")
            }
        }()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { LanaMark(size: 34); Text(copy.title).font(.title3.bold()) }
            Text(copy.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.line.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(copy.guardrail).font(.footnote).foregroundStyle(Theme.ink2)
            SimulatedNote("Simulated. Nothing is paid, sent or saved.")
            Spacer(minLength: 0)
            Button(copy.button) {
                onConfirm(r.action, copy.status + " · simulated", "Approved: \(receipt.merchant) · \(copy.status.lowercased()) (simulated)")
                asking = nil
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Not now") { asking = nil }.buttonStyle(GhostButtonStyle()).frame(maxWidth: .infinity)
        }
        .padding(20)
        .presentationDetents([.height(400)]).presentationDragIndicator(.visible).presentationBackground(Theme.sheet)
    }
}
