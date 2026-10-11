// Browser port of FWMCore's MoneyEngine.moneyView and SplitEngine.prepareSplit/allocate,
// used only by the web preview because Swift cannot run in a browser.
// Source of truth: Packages/FWMCore/Sources/FWMCore/{MoneyEngine,SplitEngine}.swift.
// engine-port.test.mjs replays the Swift golden tests against this port; if they diverge, fix the port.
(function (root) {
  "use strict";
  const MONEY_VERSION = "money-1.0", SPLIT_VERSION = "split-1.0";
  const PERIOD = /^\d{4}-(0[1-9]|1[0-2])$/;

  function toolError(code, message) { const e = new Error(message); e.code = code; return e; }

  function monthKey(iso, tz) {
    const d = new Date(iso); if (isNaN(d)) return null;
    const p = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit" }).formatToParts(d);
    return `${p.find((x) => x.type === "year").value}-${p.find((x) => x.type === "month").value}`;
  }

  function moneyView(ds, period, accountFilter) {
    if (!PERIOD.test(period)) throw toolError("INVALID_ARGUMENTS", "Which month? For example 2026-09.");
    const tz = ds.user.timezone || "America/Los_Angeles";
    const accounts = ds.accounts.filter((a) => !accountFilter || accountFilter.includes(a.account_id));
    const byId = Object.fromEntries(ds.accounts.map((a) => [a.account_id, a]));
    const inScope = new Set(accounts.map((a) => a.account_id));

    const seen = new Map();
    for (const t of ds.transactions) seen.set(t.source_id || t.transaction_id, t);
    const all = [...seen.values()].filter((t) => monthKey(t.posted_at, tz) === period)
      .sort((a, b) => (a.posted_at < b.posted_at ? -1 : a.posted_at > b.posted_at ? 1 : a.transaction_id < b.transaction_id ? -1 : a.transaction_id > b.transaction_id ? 1 : 0));
    const byPair = {};
    all.filter((t) => t.transfer_pair_id != null).forEach((t) => (byPair[t.transfer_pair_id] ||= []).push(t));

    const flow = { net_income_cents: 0, expenses_cents: 0, to_savings_cents: 0, to_investments_cents: 0, retained_cash_cents: 0, card_repayment_cents: 0 };
    const cats = new Map(), excluded = [], sources = [];
    let pending = 0;

    for (const t of all) {
      if (!inScope.has(t.account_id)) continue;
      sources.push(t.source_id || t.transaction_id);
      if (t.pending) { pending += -t.signed_amount_cents; excluded.push({ transaction_id: t.transaction_id, reason: "pending" }); continue; }
      if (t.transfer_pair_id != null) {
        const other = (byPair[t.transfer_pair_id] || []).find((o) => o.transaction_id !== t.transaction_id && o.account_id !== t.account_id);
        const otherAcct = other && byId[other.account_id];
        if (!other || !otherAcct) { excluded.push({ transaction_id: t.transaction_id, reason: "unmatchedTransfer" }); continue; }
        if (!(t.signed_amount_cents < 0)) { excluded.push({ transaction_id: t.transaction_id, reason: "transferCounterpart" }); continue; }
        const amount = -t.signed_amount_cents;
        if (otherAcct.asset_or_liability === "liability") { flow.card_repayment_cents += amount; excluded.push({ transaction_id: t.transaction_id, reason: "cardRepayment" }); }
        else if (otherAcct.kind === "savings") flow.to_savings_cents += amount;
        else if (["brokerage", "investment", "retirement"].includes(otherAcct.kind)) flow.to_investments_cents += amount;
        else excluded.push({ transaction_id: t.transaction_id, reason: "internalTransfer" });
        continue;
      }
      const category = t.category ? t.category : "Uncategorized";
      if (category === "Income" && t.signed_amount_cents > 0) { flow.net_income_cents += t.signed_amount_cents; continue; }
      const e = cats.get(category) || { total: 0, ids: [] };
      e.total += -t.signed_amount_cents; e.ids.push(t.transaction_id); cats.set(category, e);
      flow.expenses_cents += -t.signed_amount_cents;
    }
    flow.retained_cash_cents = flow.net_income_cents - flow.expenses_cents - flow.to_savings_cents - flow.to_investments_cents;

    const balances = accounts.map((a) => {
      let ok = null;
      if (a.opening_balance_cents != null) {
        const activity = all.filter((t) => t.account_id === a.account_id && !t.pending).reduce((s, t) => s + t.signed_amount_cents, 0);
        ok = (a.asset_or_liability === "asset" ? a.opening_balance_cents + activity : a.opening_balance_cents - activity) === a.balance_cents;
      }
      return { account_id: a.account_id, institution: a.institution, kind: a.kind, asset_or_liability: a.asset_or_liability,
        balance_cents: a.balance_cents, opening_balance_cents: a.opening_balance_cents, as_of: a.as_of, source_id: a.source_id, reconciled: ok };
    });
    const assets = accounts.filter((a) => a.asset_or_liability === "asset").reduce((s, a) => s + a.balance_cents, 0);
    const liabilities = accounts.filter((a) => a.asset_or_liability === "liability").reduce((s, a) => s + a.balance_cents, 0);
    const categories = [...cats.entries()].map(([category, e]) => ({ category, total_cents: e.total, transaction_ids: e.ids }))
      .sort((a, b) => b.total_cents - a.total_cents || (a.category < b.category ? -1 : a.category > b.category ? 1 : 0));
    const reconciled = categories.reduce((s, c) => s + c.total_cents, 0) === flow.expenses_cents && !balances.some((b) => b.reconciled === false);
    const filterKey = accountFilter ? [...accountFilter].sort().join("+") : "all";
    return {
      provenance: { result_id: `mv:${ds.dataset_version}:${period}:${filterKey}`, dataset_version: ds.dataset_version, data_mode: ds.data_mode,
        as_of: ds.as_of, currency: "USD", source_ids: sources, evidence_ids: [], engine_version: MONEY_VERSION },
      period, flow, categories, accounts: balances, assets_cents: assets, liabilities_cents: liabilities,
      net_worth_cents: assets - liabilities, pending_cents: pending, excluded, reconciled
    };
  }

  // Largest remainder; ties go to the earlier index (matches SplitEngine.allocate).
  function allocate(total, weights) {
    const w = weights.reduce((a, b) => a + b, 0);
    if (!(w > 0)) return allocate(total, weights.map(() => 1));
    const parts = weights.map((x) => Math.floor((total * x) / w));
    const rem = weights.map((x, i) => ({ i, r: (total * x) % w }));
    let left = total - parts.reduce((a, b) => a + b, 0);
    rem.sort((a, b) => b.r - a.r || a.i - b.i).forEach(({ i }) => { if (left > 0) { parts[i] += 1; left -= 1; } });
    return parts;
  }

  function prepareSplit({ receipt, assignments, payerId, contacts, rule = "proportional", datasetVersion = "seed-v1", dataMode = "fixture" }) {
    const itemsSum = receipt.items.reduce((s, i) => s + i.extended_price_cents, 0);
    if (Math.abs(itemsSum - receipt.subtotal_cents) > 1 || Math.abs(receipt.subtotal_cents + receipt.tax_cents + receipt.tip_cents - receipt.total_cents) > 1)
      throw toolError("RECEIPT_MISMATCH", "The receipt doesn't add up. Check the items, tax and tip before I split it.");
    const roster = Object.fromEntries(contacts.map((c) => [c.contact_id, c]));
    const people = [...new Set([...Object.values(assignments).flat(), payerId])].sort();
    const unknown = people.find((p) => !roster[p]);
    if (unknown) throw toolError("AMBIGUOUS_CONTACT", `I don't know who ${unknown} is. Pick them from your contacts first.`);
    const missing = receipt.items.find((i) => !(assignments[i.item_id] || []).length);
    if (missing) throw toolError("INVALID_ARGUMENTS", `Who had the ${missing.description}?`);

    const items = Object.fromEntries(people.map((p) => [p, 0])), taxTip = { ...items };
    const taxTipTotal = receipt.tax_cents + receipt.tip_cents;
    if (rule === "equal_total") {
      allocate(receipt.total_cents, people.map(() => 1)).forEach((c, i) => (items[people[i]] = c));
    } else {
      for (const it of receipt.items) {
        const who = [...assignments[it.item_id]].sort();
        allocate(it.extended_price_cents, who.map(() => 1)).forEach((c, i) => (items[who[i]] += c));
      }
      const weights = rule === "proportional" ? people.map((p) => items[p]) : people.map(() => 1);
      allocate(taxTipTotal, weights).forEach((c, i) => (taxTip[people[i]] = c));
    }
    const shares = people.map((p) => ({ contact_id: p, items_cents: items[p], tax_tip_cents: taxTip[p], total_cents: items[p] + taxTip[p] }));
    const payerName = roster[payerId].reviewed_name;
    const requests = shares.filter((s) => s.contact_id !== payerId).map((s) => ({
      contact_id: s.contact_id, reviewed_name: roster[s.contact_id].reviewed_name, amount_cents: s.total_cents,
      venmo_handle: roster[s.contact_id].venmo_handle || null,
      note: `${receipt.merchant || "Dinner"} ${receipt.date || ""}: your share to ${payerName}`.trim()
    }));
    return {
      provenance: { result_id: `split:${receipt.receipt_id}:${rule}`, dataset_version: datasetVersion, data_mode: dataMode, as_of: receipt.date || "",
        currency: "USD", source_ids: [receipt.receipt_id], evidence_ids: [], engine_version: SPLIT_VERSION },
      receipt_id: receipt.receipt_id, payer_id: payerId, rule, shares, requests,
      outstanding_cents: requests.reduce((s, r) => s + r.amount_cents, 0)
    };
  }

  const api = { moneyView, prepareSplit, allocate, monthKey };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.FWMEnginePort = api;
})(typeof window !== "undefined" ? window : globalThis);
