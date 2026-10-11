import SwiftUI
import FWMCore

// PREVIEW STAND-IN for the budget/swap engine and catalog (seed-v1 has catalog: []; no budget engine in
// FWMCore yet). Mirrors preview/web/preview-data.js and SRS v2 section 4. Current category totals and
// income are NOT taken from here: they come from MoneyEngine for the base month.
struct SwapOption: Identifiable, Equatable {
    let id: String, group: String, category: String, title: String, from: String, to: String
    let currentCents: Int, proposedCents: Int, reason: String
    var fromHistory = false
    var savingsCents: Int { currentCents - proposedCents }
}
struct HabitOption: Identifiable, Equatable { let id: String, category: String, title: String, savingsCents: Int, reason: String }
struct ExcludedOption: Identifiable { let id: String, title: String, savingsCents: Int, why: String, fromHistory: Bool }

enum PreviewBudgetPlan {
    static let period = "November 2026", basePeriod = "2026-09", goalCents = 15_000
    static let swaps = [
        SwapOption(id: "s_pantry", group: "pantry_staples", category: "Groceries", title: "Pantry staples", from: "Name-brand pasta, rice, beans, olive oil", to: "Store-brand equivalents, same sizes", currentCents: 9_600, proposedCents: 6_000, reason: "Same quantities by unit weight. You buy these every week."),
        SwapOption(id: "s_detergent", group: "detergent", category: "Groceries", title: "Laundry detergent", from: "Premium pods", to: "Concentrated liquid, same loads", currentCents: 3_800, proposedCents: 1_400, reason: "Compared by cost per load at your usual monthly use."),
        SwapOption(id: "s_coffee", group: "coffee_beans", category: "Other", title: "Coffee", from: "Roastery beans, 2 bags", to: "House-brand whole beans, 2 bags", currentCents: 4_000, proposedCents: 2_000, reason: "You previously rejected instant coffee, so Lana picked whole beans instead.", fromHistory: true),
        SwapOption(id: "s_phone", group: "phone_plan", category: "Bills and subscriptions", title: "Phone plan", from: "Unlimited plan", to: "Same-network plan, 30 GB", currentCents: 8_500, proposedCents: 6_500, reason: "You used under 12 GB in each of the last three months."),
    ]
    /// What the coffee slot becomes when decision history is not applied.
    static let instantCoffee = SwapOption(id: "s_coffee", group: "instant_coffee", category: "Other", title: "Coffee", from: "Roastery beans, 2 bags", to: "Instant coffee, 2 jars", currentCents: 4_000, proposedCents: 1_000, reason: "Cheapest comparable option. No decision history was used.")
    static let habits = [
        HabitOption(id: "h_dining", category: "Dining", title: "One fewer delivery order", savingsCents: 2_000, reason: "Dining was four orders in September."),
        HabitOption(id: "h_transport", category: "Transport", title: "Transit for two short trips", savingsCents: 1_000, reason: "Two rideshares could have been transit."),
        HabitOption(id: "h_other", category: "Other", title: "Trim small extras", savingsCents: 2_000, reason: "A smaller cap on general shopping."),
    ]
    static let excluded = [
        ExcludedOption(id: "x_instant", title: "Instant coffee", savingsCents: 3_000, why: "You previously rejected instant coffee.", fromHistory: true),
        ExcludedOption(id: "x_oat", title: "Store-brand oat milk", savingsCents: 900, why: "You asked to keep your preferred oat milk.", fromHistory: false),
    ]
}

/// Journey 2: budget proposal with reviewable swaps. Adopting changes the budget only.
struct BudgetScreen: View {
    let store: DemoStore
    var onAdopt: (String) -> Void = { _ in }
    @State private var accepted = Set(PreviewBudgetPlan.swaps.map(\.id) + PreviewBudgetPlan.habits.map(\.id))
    @State private var useHistory = true
    @State private var adoptedSignature: String?
    @State private var reviewing = false
    @State private var showWhy = false

    private var swaps: [SwapOption] { useHistory ? PreviewBudgetPlan.swaps : PreviewBudgetPlan.swaps.map { $0.id == "s_coffee" ? PreviewBudgetPlan.instantCoffee : $0 } }
    private var signature: String { accepted.sorted().joined(separator: ",") + "|\(useHistory)" }

    private struct Plan { var current: [CategoryTotal]; var target: [String: Int]; var reduction: Int; var flow: MoneyFlow }
    private func plan() -> Plan? {
        guard case .success(let v) = store.moneyView(PreviewBudgetPlan.basePeriod) else { return nil }
        var target = Dictionary(uniqueKeysWithValues: v.categories.map { ($0.category, $0.totalCents) })
        for s in swaps where accepted.contains(s.id) { target[s.category, default: 0] -= s.savingsCents }
        for h in PreviewBudgetPlan.habits where accepted.contains(h.id) { target[h.category, default: 0] -= h.savingsCents }
        let reduction = v.flow.expensesCents - target.values.reduce(0, +)
        return Plan(current: v.categories, target: target, reduction: reduction, flow: v.flow)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let p = plan() { content(p) } else { Card { Text("Couldn’t load September totals.") } }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                // The adopt button is at the bottom and its confirmation banner at the top; show the banner.
                .onChange(of: adoptedSignature) { _, _ in withAnimation { proxy.scrollTo("adopted", anchor: .center) } }
            }
            .background(Theme.bg)
            .navigationTitle("Budget")
            .toolbar { DemoDataBadge() }
            .sheet(isPresented: $showWhy) { whySheet }
        }
    }

    @ViewBuilder private func content(_ p: Plan) -> some View {
        let goal = PreviewBudgetPlan.goalCents
        let changed = adoptedSignature != nil && adoptedSignature != signature
        let rent = p.current.first { $0.category == "Rent" }?.totalCents ?? 0
        MessagePreview(question: "Help me save $150 next month without changing my rent.",
                       answer: "Here’s a plan that keeps rent at \(usd(rent)) and frees up \(usd(goal)) a month: four swaps worth $100 and three small habit changes worth $50.")
        Text("\(usd(p.reduction)) a month, projected").font(Theme.display(32)).padding(.top, 6)
        Text((p.reduction >= goal ? "Meets your $150 goal." : "\(usd(goal - p.reduction)) short of your $150 goal.") + " A plan for \(PreviewBudgetPlan.period). Nothing is saved until you spend less.")
            .foregroundStyle(Theme.ink2)
        if adoptedSignature != nil {
            Label(changed ? "Edited since adopting. Review and adopt again." : "Adopted. Balances and purchases are unchanged.", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(Theme.accent).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                .id("adopted")
        }
        Card {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("CATEGORY"); Text("SEP").gridColumnAlignment(.trailing); Text("PLAN").gridColumnAlignment(.trailing) }
                    .font(.caption2.weight(.bold)).foregroundStyle(Theme.ink3)
                ForEach(p.current, id: \.category) { c in
                    let t = p.target[c.category] ?? c.totalCents
                    GridRow {
                        Text(c.category.replacingOccurrences(of: " and subscriptions", with: " & subs"))
                            .frame(maxWidth: .infinity, alignment: .leading) // category column takes the slack so amounts sit at the card edge
                        Text(usd(c.totalCents)).foregroundStyle(Theme.ink3)
                        Text(usd(t)).fontWeight(t < c.totalCents ? .semibold : .regular).foregroundStyle(t < c.totalCents ? Theme.accent : Theme.ink)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow { Text("Total").bold(); Text(usd(p.flow.expensesCents)).foregroundStyle(Theme.ink3); Text(usd(p.flow.expensesCents - p.reduction)).bold() }
            }
            .monospacedDigit()
            HStack { Text("To savings & investing").foregroundStyle(Theme.ink3); Spacer(); Text("\(usd(p.flow.toSavingsCents + p.flow.toInvestmentsCents)) · unchanged") }.font(.subheadline)
            HStack { Text("Kept in checking").foregroundStyle(Theme.ink3); Spacer(); Text("\(usd(p.flow.retainedCashCents)) → ") + Text(usd(p.flow.retainedCashCents + p.reduction)).bold().foregroundColor(Theme.accent) }.font(.subheadline)
        }
        SectionLabel("Your rules")
        FlowChips(items: ["Keep rent at \(usd(rent))", "Keep my preferred oat milk"] + (useHistory ? ["No instant coffee"] : []))
        SectionLabel("Swaps · \(usd(swaps.filter { accepted.contains($0.id) }.reduce(0) { $0 + $1.savingsCents }))")
        ForEach(swaps) { s in
            OptionCard(title: s.title, savings: s.savingsCents, isOn: binding(s.id), fromHistory: s.fromHistory, reason: s.reason) {
                (Text(s.from).strikethrough().foregroundColor(Theme.ink3) + Text(" \(usd(s.currentCents))").bold()
                 + Text("\n→ \(s.to) ") + Text(usd(s.proposedCents)).bold())
            }
        }
        Text("Prices are illustrative demo assumptions, not live quotes.").font(.caption).foregroundStyle(Theme.ink3)
        SectionLabel("Habits · \(usd(PreviewBudgetPlan.habits.filter { accepted.contains($0.id) }.reduce(0) { $0 + $1.savingsCents }))")
        ForEach(PreviewBudgetPlan.habits) { h in
            OptionCard(title: h.title, savings: h.savingsCents, isOn: binding(h.id), fromHistory: false, reason: h.reason) { Text("\(h.category) · habit change") }
        }
        SectionLabel("Left out on purpose")
        Card {
            ForEach(PreviewBudgetPlan.excluded.filter { useHistory || !$0.fromHistory }) { x in
                HStack { VStack(alignment: .leading) { Text(x.title).fontWeight(.semibold); Text(x.why).font(.caption).foregroundStyle(Theme.ink3) }
                    Spacer(); Text("\(usd(x.savingsCents))/mo").foregroundStyle(Theme.ink3).monospacedDigit() }
            }
            Button("Why these suggestions?") { showWhy = true }.foregroundStyle(Theme.accent).fontWeight(.semibold)
        }
        Button(adoptedSignature != nil && !changed ? "Plan adopted" : "Review & adopt plan") { reviewing = true }
            .buttonStyle(PrimaryButtonStyle()).disabled(adoptedSignature != nil && !changed).padding(.top, 8)
            .confirmationDialog("Adopt budget for \(PreviewBudgetPlan.period)?", isPresented: $reviewing, titleVisibility: .visible) {
                Button("Adopt plan · \(usd(p.reduction))/mo projected") {
                    guard adoptedSignature != signature else { return } // duplicate tap does nothing
                    adoptedSignature = signature
                    onAdopt("Budget for \(PreviewBudgetPlan.period) · \(usd(p.reduction))/mo projected")
                }
            } message: {
                Text("This updates your budget only. It doesn’t move money, change account balances, buy products or switch your phone plan.")
            }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { accepted.contains(id) }, set: { if $0 { accepted.insert(id) } else { accepted.remove(id) } })
    }

    private var whySheet: some View {
        NavigationStack {
            Form {
                Section { Text("Lana checks your past swap decisions before suggesting alternatives. Your own rules always win.") }
                Section("Evidence") {
                    LabeledContent("History checked", value: "Oct 11, 12:58 PM")
                    LabeledContent("Past decisions", value: "Rejected instant coffee 3 times")
                    LabeledContent("Effect", value: useHistory ? "Instant coffee left out" : "Not applied")
                }
                Section {
                    Toggle("Use decision history", isOn: $useHistory)
                    SimulatedNote("Demo adapter with synthetic history. Not a verified Keewano connection.")
                }
            }
            .navigationTitle("Why these suggestions?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline) // the large title truncates at phone width
            #endif
            .toolbar { Button("Done") { showWhy = false } }
        }
        .presentationDetents([.large])
    }
}

struct OptionCard<Detail: View>: View {
    let title: String
    let savings: Int
    @Binding var isOn: Bool
    let fromHistory: Bool
    let reason: String
    @ViewBuilder var detail: Detail
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(usd(savings))/mo").fontWeight(.bold).foregroundStyle(Theme.accent).monospacedDigit() }
            detail.font(.subheadline).foregroundStyle(Theme.ink2)
            HStack(alignment: .top, spacing: 6) {
                if fromHistory { Tag(text: "From your history", tone: Theme.accent, fill: Theme.accentSoft) }
                Text(reason).font(.footnote)
            }
            Picker(title, selection: $isOn) { Text("Keep").tag(true); Text("Skip").tag(false) }.pickerStyle(.segmented).frame(maxWidth: 200)
        }
        .padding(14)
        .background(isOn ? Theme.card : Color.clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        .opacity(isOn ? 1 : 0.6)
        .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

struct FlowChips: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { t in
                Label(t, systemImage: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.accentSoft, in: Capsule())
            }
        }
    }
}
