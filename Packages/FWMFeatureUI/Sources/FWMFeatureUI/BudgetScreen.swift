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

/// One swipeable suggestion: a product/service swap or a habit change.
struct BudgetIdea: Identifiable, Equatable {
    let id: String, category: String, title: String, savingsCents: Int, reason: String
    var from: String?, to: String?, currentCents: Int?, proposedCents: Int?
    var fromHistory = false
    /// What Lana would do if asked to follow through: buy or switch for a swap, a nudge for a habit.
    var action: String
    let isSwap: Bool
    /// Plans are switched; everything else in the demo catalog is bought on the next order.
    var isSwitch: Bool { id == "s_phone" }
    var question: String { !isSwap ? "Remind you?" : (isSwitch ? "Switch it for you?" : "Buy it for you?") }
    var approveLabel: String { !isSwap ? "Remind me" : (isSwitch ? "Switch plan" : "Buy for \(usd(proposedCents ?? 0))") }
    /// Short verb for acting later from the plan list.
    var laterLabel: String { !isSwap ? "Remind" : (isSwitch ? "Switch" : "Buy") }
    var handledStatus: String { !isSwap ? "Weekly reminder · simulated" : (isSwitch ? "Switch requested · simulated" : "On next order · simulated") }
    var safeguard: String { !isSwap ? "One nudge a week in Messages. Turn it off any time." : (isSwitch ? "You confirm with your carrier before anything changes." : "You approve the cart before anything is charged.") }

    /// The follow-through Lana offers for each swap. Bounded demo copy; no purchase integration exists yet.
    static let actions = [
        "s_pantry": "Put the store-brand staples in your next grocery order",
        "s_detergent": "Swap the detergent in your next grocery order",
        "s_coffee": "Order the house-brand beans when you next run out",
        "s_phone": "Ask your carrier to move you to the 30 GB plan",
    ]
    init(_ s: SwapOption) {
        id = s.id; category = s.category; title = s.title; savingsCents = s.savingsCents; reason = s.reason
        from = s.from; to = s.to; currentCents = s.currentCents; proposedCents = s.proposedCents; fromHistory = s.fromHistory
        action = Self.actions[s.id] ?? "Make this switch for you"; isSwap = true
    }
    init(_ h: HabitOption) {
        id = h.id; category = h.category; title = h.title; savingsCents = h.savingsCents; reason = h.reason
        action = "Nudge you about this once a week"; isSwap = false
    }
}

/// Journey 2: spending by category, then one suggestion at a time to keep or skip. Keeping a swap asks
/// whether Lana should carry it out; every approval is explicit and, in this build, simulated.
struct BudgetScreen: View {
    let store: DemoStore
    let unlocker: VaultUnlocking
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorizing = false
    @State private var approvalError: String?
    /// Kept idea ids and the history toggle, for the chat tools' shared projection.
    var onSelection: (Set<String>, Bool) -> Void = { _, _ in }
    var onAdopt: (String) -> Void = { _ in }
    var onApprove: (String) -> Void = { _ in }
    /// Monthly savings currently kept in the plan, so Home and chat can reflect it.
    var onPlanChange: (Int) -> Void = { _ in }

    enum Handling: Equatable { case lana, me }
    @State private var decisions: [String: Bool] = [:]   // idea id → kept
    @State private var handling: [String: Handling] = [:]
    @State private var order: [String] = []               // decision order, for undo
    @State private var category: String?
    @State private var drag: CGSize = .zero
    @State private var asking: BudgetIdea?
    @State private var useHistory = true
    @State private var adoptedSignature: String?
    @State private var reviewing = false
    @State private var showWhy = false

    private var swaps: [SwapOption] { useHistory ? PreviewBudgetPlan.swaps : PreviewBudgetPlan.swaps.map { $0.id == "s_coffee" ? PreviewBudgetPlan.instantCoffee : $0 } }
    private var ideas: [BudgetIdea] { swaps.map(BudgetIdea.init) + PreviewBudgetPlan.habits.map(BudgetIdea.init) }
    private func ideas(in c: String) -> [BudgetIdea] { ideas.filter { $0.category == c } }
    private func pending(in c: String) -> [BudgetIdea] { ideas(in: c).filter { decisions[$0.id] == nil } }
    private var kept: [BudgetIdea] { ideas.filter { decisions[$0.id] == true } }
    private var signature: String { decisions.filter(\.value).keys.sorted().joined(separator: ",") + "|\(useHistory)" }

    private struct Plan { var current: [CategoryTotal]; var target: [String: Int]; var reduction: Int; var flow: MoneyFlow }
    private func plan() -> Plan? {
        guard let p = try? BudgetProjection.make(dataset: store.dataset, period: PreviewBudgetPlan.basePeriod, accepted: Set(kept.map(\.id)), useHistory: useHistory) else { return nil }
        return Plan(current: p.current.categories, target: p.targets, reduction: p.savingsCents, flow: p.current.flow)
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
                .onChange(of: adoptedSignature) { _, _ in withAnimation { proxy.scrollTo("adopted", anchor: .center) } }
            }
            .scrollIndicators(.hidden).background { Theme.backdrop }
            .navigationTitle("Budget")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline) // keeps the swipe card and its buttons on one screen
            #endif
            .toolbar { DemoDataBadge() }
            .sheet(isPresented: $showWhy) { whySheet }
            .sheet(item: $asking) { askSheet($0) }
            .onAppear { if category == nil { category = plan()?.current.first { !pending(in: $0.category).isEmpty }?.category } }
            .onChange(of: signature) { _, _ in
                onSelection(Set(kept.map(\.id)), useHistory)
                onPlanChange(kept.reduce(0) { $0 + $1.savingsCents })
            }
        }
    }

    @ViewBuilder private func content(_ p: Plan) -> some View {
        let changed = adoptedSignature != nil && adoptedSignature != signature
        progress(p)
        if adoptedSignature != nil {
            Label(changed ? "Edited since adopting. Adopt again to update." : "Adopted for this session. Balances and purchases are unchanged.", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(Theme.accent).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16)).id("adopted")
        }
        categories(p).padding(.top, 4)
        if let c = category {
            HStack { Eyebrow("Ideas for \(short(c))"); Spacer()
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.font(.footnote.weight(.semibold)).disabled(order.isEmpty)
                Text("·").foregroundStyle(Theme.ink3)
                Button("Why these?") { showWhy = true }.font(.footnote.weight(.semibold)) }
                .padding(.horizontal, 4).padding(.top, 6)
            deck(c, p)
        }
        if !kept.isEmpty { planCard(p, changed: changed) }
    }

    private func short(_ c: String) -> String { c.replacingOccurrences(of: " and subscriptions", with: " & subs") }

    // MARK: goal progress

    private func progress(_ p: Plan) -> some View {
        let goal = PreviewBudgetPlan.goalCents, met = p.reduction >= goal
        let left = ideas.filter { decisions[$0.id] == nil }.count
        return HStack(spacing: 16) {
            RingChart(segments: [.init(label: "In your plan", cents: min(max(p.reduction, 0), goal), color: met ? Theme.ok : Theme.accent)], total: goal, diameter: 76, lineWidth: 10) {
                Text("\(min(100, p.reduction * 100 / max(goal, 1)))%").font(.system(size: 17, weight: .bold)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Save \(usd(goal)) in \(PreviewBudgetPlan.period.components(separatedBy: " ").first ?? "") · rent unchanged")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HeroAmount(cents: p.reduction, size: 34)
                    Text("of \(usd(goal))").font(.subheadline).foregroundStyle(Theme.ink2)
                }
                Text(met ? "Goal met" : "\(left) \(left == 1 ? "idea" : "ideas") left" + (kept.isEmpty ? "" : " · \(usd(goal - p.reduction)) to go"))
                    .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 3)
                    .foregroundStyle(met ? Theme.ok : Theme.accent).background(met ? Theme.okSoft : Theme.accentSoft, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).raised(24)
        .animation(.spring(duration: 0.4), value: p.reduction)
    }

    // MARK: categories

    /// A row of category tiles: what was spent, what the plan brings it to, and how many ideas are left.
    private static func icon(_ category: String) -> String {
        ["Rent": "🏠", "Groceries": "🛒", "Dining": "🍜", "Transport": "🚇", "Bills and subscriptions": "📱", "Other": "🛍️"][category] ?? "•"
    }

    private func categories(_ p: Plan) -> some View {
        let maxC = CGFloat(p.current.map(\.totalCents).max() ?? 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Categories with ideas first, biggest spend first; fixed ones (rent) at the end.
                ForEach(p.current.filter { !ideas(in: $0.category).isEmpty } + p.current.filter { ideas(in: $0.category).isEmpty }, id: \.category) { c in
                    let all = ideas(in: c.category), left = pending(in: c.category).count
                    let target = p.target[c.category] ?? c.totalCents, on = category == c.category
                    Button { if !all.isEmpty { withAnimation(.spring(duration: 0.3)) { category = c.category; drag = .zero } } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) { Text(Self.icon(c.category)); Text(short(c.category)).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85) }
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(usd(target)).font(.title3.weight(.bold)).foregroundStyle(on ? .white : (target < c.totalCents ? Theme.ok : Theme.ink))
                                if target < c.totalCents { Text(usd(c.totalCents)).font(.caption).strikethrough().opacity(0.7) }
                            }
                            .monospacedDigit()
                            Capsule().fill(on ? Color.white.opacity(0.25) : Theme.line).frame(height: 4).overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(on ? Color.white : Theme.spent).frame(width: g.size.width * CGFloat(target) / maxC) }
                            }
                            badge(all: all.count, left: left, on: on)
                        }
                        .foregroundStyle(on ? .white : Theme.ink)
                        .padding(12).frame(width: 128, alignment: .leading)
                        .background(on ? AnyShapeStyle(Theme.deepBlueFill) : AnyShapeStyle(Theme.cardFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .raised(18, tint: on ? Theme.deepBlue : .black, strength: on ? 2 : 1)
                        .opacity(all.isEmpty ? 0.6 : 1)
                    }
                    .buttonStyle(PressScaleStyle()).disabled(all.isEmpty)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .padding(.horizontal, -16).padding(.vertical, -10)
    }

    @ViewBuilder private func badge(all: Int, left: Int, on: Bool) -> some View {
        if all == 0 { Tag(text: "Fixed") }
        else if left == 0 { Tag(text: "Reviewed", tone: on ? .white : Theme.ok, fill: on ? .white.opacity(0.22) : Theme.okSoft) }
        else { Tag(text: left == 1 ? "1 idea" : "\(left) ideas", tone: on ? .white : Theme.accent, fill: on ? .white.opacity(0.22) : Theme.accentSoft) }
    }

    // MARK: swipe deck

    @ViewBuilder private func deck(_ c: String, _ p: Plan) -> some View {
        let queue = pending(in: c)
        if let top = queue.first {
            ZStack {
                if queue.count > 1 { ideaCard(queue[1]).scaleEffect(0.95).offset(y: 12).opacity(0.6).allowsHitTesting(false).accessibilityHidden(true) }
                ideaCard(top)
                    .overlay(alignment: .topLeading) { stamp("KEEP", Theme.ok).opacity(Double(max(0, drag.width) / 90)).padding(16) }
                    .overlay(alignment: .topTrailing) { stamp("SKIP", Theme.bad).opacity(Double(max(0, -drag.width) / 90)).padding(16) }
                    .offset(x: drag.width, y: drag.height * 0.15).rotationEffect(.degrees(Double(drag.width) / 22))
                    .gesture(DragGesture(minimumDistance: 12)
                        .onChanged { drag = $0.translation }
                        .onEnded { v in
                            if abs(v.translation.width) > 90 { fling(top, keep: v.translation.width > 0) }
                            else { withAnimation(.spring(duration: 0.3)) { drag = .zero } }
                        })
                    .accessibilityAction(named: "Keep") { fling(top, keep: true) }
                    .accessibilityAction(named: "Skip") { fling(top, keep: false) }
                    .id(top.id)
            }
            .padding(.bottom, queue.count > 1 ? 12 : 0)
            // Spread to the sides so neither button sits under the Lana orb.
            HStack {
                round("xmark", Theme.bad, "Skip") { fling(top, keep: false) }
                Spacer()
                Text("\(ideas(in: c).count - queue.count + 1) of \(ideas(in: c).count)").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink2).monospacedDigit()
                Spacer()
                round("checkmark", Theme.ok, "Keep") { fling(top, keep: true) }
            }
            .padding(.horizontal, 28).padding(.top, 4)
        } else {
            let mine = ideas(in: c).filter { decisions[$0.id] == true }
            Card {
                Label("\(short(c)) reviewed", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Theme.ok)
                Text(mine.isEmpty ? "Nothing kept here." : "Kept \(mine.count) · \(usd(mine.reduce(0) { $0 + $1.savingsCents }))/mo").font(.subheadline).foregroundStyle(Theme.ink2)
                HStack {
                    if let next = p.current.first(where: { !pending(in: $0.category).isEmpty }) {
                        Button("Next: \(short(next.category))") { withAnimation { category = next.category } }.buttonStyle(PrimaryButtonStyle())
                    }
                    Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.buttonStyle(GhostButtonStyle()).disabled(order.isEmpty)
                }
            }
        }
    }

    private func ideaCard(_ i: BudgetIdea) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(i.isSwap ? "Swap" : "Habit")
                    Text(i.title).font(.title2.bold())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(usd(i.savingsCents)).font(.system(size: 30, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ok)
                    Text("saved / mo").font(.caption).foregroundStyle(Theme.ink2)
                }
            }
            if let from = i.from, let to = i.to, let cur = i.currentCents, let prop = i.proposedCents {
                VStack(spacing: 0) {
                    line("Now", from, usd(cur), faded: true)
                    Divider()
                    line("Instead", to, usd(prop), faded: false)
                }
                .padding(.horizontal, 12).background(Theme.line.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(alignment: .top, spacing: 6) {
                if i.fromHistory { Tag(text: "From your history", tone: Theme.accent, fill: Theme.accentSoft) }
                Text(i.reason).font(i.isSwap ? .footnote : .subheadline).foregroundStyle(Theme.ink2)
            }
            if !i.isSwap { Label("No purchase needed. Lana can remind you.", systemImage: "bell").font(.footnote).foregroundStyle(Theme.ink2) }
            if i.isSwap { Text("Demo prices, not live quotes.").font(.caption2).foregroundStyle(Theme.ink3) }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: i.isSwap ? 210 : 0, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .raised(26, strength: 1.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Swipe right to keep, left to skip")
    }

    private func line(_ k: String, _ what: String, _ price: String, faded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink2).frame(width: 52, alignment: .leading)
            Text(what).font(.subheadline).strikethrough(faded).foregroundStyle(faded ? Theme.ink2 : Theme.ink)
            Spacer(minLength: 4)
            Text(price).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(faded ? Theme.ink2 : Theme.ink)
        }
        .padding(.vertical, 10)
    }

    private func stamp(_ t: String, _ c: Color) -> some View {
        Text(t).font(.headline.weight(.heavy)).tracking(1.5).foregroundStyle(c).padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c, lineWidth: 2.5)).rotationEffect(.degrees(t == "KEEP" ? -10 : 10))
    }

    private func round(_ icon: String, _ c: Color, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2.weight(.bold)).foregroundStyle(c).frame(width: 60, height: 60)
                .background(Theme.cardFill, in: Circle()).raised(30, tint: c, strength: 1.8)
        }
        .buttonStyle(PressScaleStyle()).accessibilityLabel(label)
    }

    private func fling(_ i: BudgetIdea, keep: Bool) {
        guard decisions[i.id] == nil else { return } // a second tap mid-animation does nothing
        withAnimation(.easeIn(duration: 0.22)) { drag = CGSize(width: keep ? 520 : -520, height: 30) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            decisions[i.id] = keep; order.append(i.id); drag = .zero
            if keep { asking = i }
        }
    }

    private func undo() {
        guard let last = order.popLast() else { return }
        withAnimation(.spring(duration: 0.3)) {
            decisions[last] = nil; handling[last] = nil
            if let i = ideas.first(where: { $0.id == last }) { category = i.category }
        }
    }

    // MARK: "want me to handle it?"

    private func askSheet(_ i: BudgetIdea) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { LanaOrb(size: 36); Text(i.question).font(.title3.bold()) }
            VStack(alignment: .leading, spacing: 8) {
                Text(i.isSwap ? i.action : "\(i.title): \(i.action.prefix(1).lowercased() + i.action.dropFirst())").font(.headline).fixedSize(horizontal: false, vertical: true)
                if let to = i.to, let prop = i.proposedCents, let cur = i.currentCents {
                    Text("\(to), \(usd(prop)) instead of \(usd(cur)).").font(.subheadline).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Text("Saves \(usd(i.savingsCents)) a month").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ok)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.line.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(i.safeguard).font(.footnote).foregroundStyle(Theme.ink2)
            SimulatedNote("Simulated. Nothing is bought, sent or switched.")
            Spacer(minLength: 0)
            Button(i.approveLabel) {
                if handling[i.id] != .lana { // duplicate tap guard
                    handling[i.id] = .lana
                    onApprove(i.isSwap ? "Approved: \(i.title) · \(i.isSwitch ? "switch" : "buy") for \(usd(i.proposedCents ?? 0)) (simulated, nothing charged)"
                                       : "Approved: weekly reminder · \(i.title) (simulated, nothing sent)")
                }
                asking = nil
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Just add to plan") { handling[i.id] = .me; asking = nil }.buttonStyle(GhostButtonStyle()).frame(maxWidth: .infinity)
        }
        .padding(20)
        .presentationDetents([.height(i.isSwap ? 450 : 400)]).presentationDragIndicator(.visible)
        .onDisappear { if handling[i.id] == nil { handling[i.id] = .me } } // dismissing never authorizes Lana
    }

    // MARK: plan summary + adopt

    private func planCard(_ p: Plan, changed: Bool) -> some View {
        let done = adoptedSignature != nil && !changed
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Your plan · \(usd(p.reduction))/mo")
            Card {
                ForEach(kept) { i in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title).fontWeight(.semibold)
                            Text(handling[i.id] == .lana ? i.handledStatus : "\(usd(i.savingsCents))/mo · in plan")
                                .font(.caption).foregroundStyle(handling[i.id] == .lana ? Theme.warn : Theme.ink2)
                        }
                        Spacer()
                        if handling[i.id] == .lana {
                            Text("\(usd(i.savingsCents))/mo").fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.ok)
                        } else {
                            // Chosen "Just add to plan": the follow-through stays one tap away.
                            Button(i.laterLabel) { asking = i }.buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                Divider()
                HStack { Text("Kept in checking").foregroundStyle(Theme.ink2); Spacer()
                    Text("\(usd(p.flow.retainedCashCents)) → ") + Text(usd(p.flow.retainedCashCents + p.reduction)).bold().foregroundColor(Theme.ok) }
                    .font(.subheadline).monospacedDigit()
            }
            if let approvalError { Text(approvalError).font(.footnote).foregroundStyle(Theme.bad) }
            Button(authorizing ? "Authorizing…" : (done ? "Plan adopted" : "Adopt plan · \(usd(p.reduction))/mo")) { reviewing = true }
                .buttonStyle(PrimaryButtonStyle()).disabled(done || authorizing).opacity(done ? 0.5 : 1)
                .confirmationDialog("Adopt budget for \(PreviewBudgetPlan.period)?", isPresented: $reviewing, titleVisibility: .visible) {
                    Button("Adopt plan · \(usd(p.reduction))/mo projected") {
                        guard adoptedSignature != signature else { return } // duplicate tap does nothing
                        let reviewedSignature = signature
                        authorizing = true; approvalError = nil
                        Task {
                            defer { authorizing = false }
                            do {
                                try await unlocker.authenticateDeviceOwner(reason: "Adopt the reviewed demo budget")
                                guard reviewedSignature == signature, scenePhase == .active else {
                                    approvalError = "The plan changed or the app became inactive. Review it again."; return
                                }
                                guard adoptedSignature != reviewedSignature else { return }
                                adoptedSignature = reviewedSignature
                                onAdopt("Demo budget adopted for this session · \(usd(p.reduction))/mo projected")
                            } catch { approvalError = error.localizedDescription }
                        }
                    }
                } message: {
                    Text("This updates your budget only. Savings are projected, not money already saved, and no account balance changes.")
                }
        }
    }

    private var whySheet: some View {
        NavigationStack {
            Form {
                Section("Your rules") {
                    Label("Keep rent unchanged", systemImage: "checkmark")
                    Label("Keep my preferred oat milk", systemImage: "checkmark")
                    if useHistory { Label("No instant coffee", systemImage: "checkmark") }
                }
                Section("Left out on purpose") {
                    ForEach(PreviewBudgetPlan.excluded.filter { useHistory || !$0.fromHistory }) { x in
                        LabeledContent(x.title, value: "\(usd(x.savingsCents))/mo")
                    }
                }
                Section("Evidence") {
                    LabeledContent("History checked", value: "Oct 11, 12:58 PM")
                    LabeledContent("Past decisions", value: "Rejected instant coffee 3 times")
                    LabeledContent("Effect", value: useHistory ? "Instant coffee left out" : "Not applied")
                }
                Section {
                    Toggle("Use decision history", isOn: $useHistory)
                    SimulatedNote("Simulated. Not a live Keewano connection.")
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

