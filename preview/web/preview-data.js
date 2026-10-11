// Preview-only inputs that the shared fixtures don't contain yet. Everything else is read from
// fixtures/seed-v1.json and computed with engine-port.js (a tested port of FWMCore's engines).
// Replace each block when its owner lands the real source. Money is integer USD cents.
window.LanaPreview = {
  // BUDGET PLAN STAND-IN. seed-v1.json has catalog: [] and FWMCore has no budget engine yet.
  // Swaps/habits follow SRS v2 section 4. Group ids match relay/scripts/seed-keewano.ts.
  // Current category totals are NOT taken from here; they come from moneyView(seed, "2026-09").
  budget: {
    result_id: "budget-preview:seed-v1:2026-11", period: "November 2026", base_period: "2026-09", extra_savings_cents: 15000,
    constraints: [
      { id: "c_rent", text: "Keep rent at $1,600", source: "Your request" },
      { id: "c_oat", text: "Keep my preferred oat milk", source: "Your preference (brand lock)" },
      { id: "c_instant", text: "No instant coffee", source: "Learned from past decisions" }
    ],
    swaps: [
      { id: "s_pantry", group: "pantry_staples", category: "Groceries", title: "Pantry staples", from: "Name-brand pasta, rice, beans, olive oil", to: "Store-brand equivalents, same sizes", cur: 9600, next: 6000, reason: "Same quantities by unit weight. You buy these every week." },
      { id: "s_detergent", group: "detergent", category: "Groceries", title: "Laundry detergent", from: "Premium pods", to: "Concentrated liquid, same loads", cur: 3800, next: 1400, reason: "Compared by cost per load at your usual monthly use." },
      { id: "s_coffee", group: "coffee_beans", category: "Other", title: "Coffee", from: "Roastery beans, 2 bags", to: "House-brand whole beans, 2 bags", cur: 4000, next: 2000, reason: "You previously rejected instant coffee, so Lana picked whole beans instead.", memory: true },
      { id: "s_phone", group: "phone_plan", category: "Bills and subscriptions", title: "Phone plan", from: "Unlimited plan", to: "Same-network plan, 30 GB", cur: 8500, next: 6500, reason: "You used under 12 GB in each of the last three months." }
    ],
    // Shown only when decision history is turned off, to demonstrate that it changes the plan.
    without_memory: { replaces: "s_coffee", group: "instant_coffee", to: "Instant coffee, 2 jars", next: 1000, reason: "Cheapest comparable option. No decision history was used." },
    excluded: [
      { id: "x_instant", group: "instant_coffee", title: "Instant coffee", savings: 3000, why: "You previously rejected instant coffee.", memory: true },
      { id: "x_oat", title: "Store-brand oat milk", savings: 900, why: "You asked to keep your preferred oat milk." }
    ],
    habits: [
      { id: "h_dining", category: "Dining", title: "One fewer delivery order", savings: 2000, reason: "Dining was four orders in September." },
      { id: "h_transport", category: "Transport", title: "Transit for two short trips", savings: 1000, reason: "Two rideshares could have been transit." },
      { id: "h_other", category: "Other", title: "Trim small extras", savings: 2000, reason: "A smaller cap on general shopping." }
    ],
    memory: { provider: "Keewano", evidence_count: 3, queried_at: "Oct 11, 12:58 PM" }
  },

  // RECEIPT + VOICE DEMO INPUTS. The receipt itself is fixtures/seed-v1.json receipts[0].
  split: {
    transcript: "I paid for dinner with Tanish and Aryan. Split the appetizer evenly and divide tax and tip proportionally.",
    // Simulated low-confidence OCR read so the correction step can be shown. The fixture value is the truth.
    ocr_misread: { field: "tip_cents", read: 1630, confidence: 0.58 }
  },

  // Synthetic vault entries. Never real secrets.
  vault: [
    { id: "v1", label: "Messaging line token", scope: "Send and receive messages", value: "demo_dial_7Q2x-9fLm-aa41" },
    { id: "v2", label: "Bank sandbox connection", scope: "Read balances and transactions", value: "demo_sbx_acc_55e1c0" },
    { id: "v3", label: "Preference history key", scope: "Read past swap decisions", value: "demo_kw_3b9d-11ce" },
    { id: "v4", label: "Payment handle", scope: "Prefill request drafts", value: "@ashwin-demo" }
  ]
};
