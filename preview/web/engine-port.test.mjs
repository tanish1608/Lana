// Replays Packages/FWMCore/Tests/FWMCoreTests/EngineTests.swift against the browser port.
// Run from the repo root: node --test preview/web/engine-port.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const E = require("./engine-port.js");
const load = (f) => JSON.parse(readFileSync(new URL(`../../fixtures/${f}`, import.meta.url)));
const totals = (v) => Object.fromEntries(v.categories.map((c) => [c.category, c.total_cents]));

test("canonical September", () => {
  const v = E.moneyView(load("seed-v1.json"), "2026-09");
  assert.deepEqual([v.flow.net_income_cents, v.flow.expenses_cents, v.flow.to_savings_cents, v.flow.to_investments_cents, v.flow.retained_cash_cents],
    [480000, 315000, 65000, 40000, 60000]);
  assert.deepEqual(totals(v), { Rent: 160000, Groceries: 50000, Dining: 30000, Transport: 25000, "Bills and subscriptions": 25000, Other: 25000 });
  assert.equal(v.assets_cents, 2445000); assert.equal(v.liabilities_cents, 1290000); assert.equal(v.net_worth_cents, 1155000);
  assert.equal(v.reconciled, true); assert.equal(v.provenance.result_id, "mv:seed-v1:2026-09:all");
});

test("edge cases do not inflate spending", () => {
  const ds = load("edge-v1.json"), v = E.moneyView(ds, "2026-09"), x = ds.expected;
  assert.equal(v.flow.net_income_cents, x.net_income_cents); assert.equal(v.flow.expenses_cents, x.expenses_cents);
  assert.equal(v.flow.to_savings_cents, x.to_savings_cents); assert.equal(v.flow.card_repayment_cents, x.card_repayment_cents);
  assert.equal(v.pending_cents, x.pending_cents); assert.deepEqual(totals(v), x.categories_cents);
  assert.ok(v.excluded.some((e) => e.transaction_id === "e4" && e.reason === "cardRepayment"));
  assert.ok(v.excluded.some((e) => e.transaction_id === "e8" && e.reason === "pending"));
  assert.equal(v.reconciled, true);
});

test("rejects bad period", () => assert.throws(() => E.moneyView(load("seed-v1.json"), "last month"), { code: "INVALID_ARGUMENTS" }));

test("dinner receipt", () => {
  const ds = load("seed-v1.json"), ex = ds.split_example;
  const r = E.prepareSplit({ receipt: ds.receipts[0], assignments: ex.assignments, payerId: ex.payer_id, contacts: ds.contacts });
  assert.deepEqual(Object.fromEntries(r.shares.map((s) => [s.contact_id, s.total_cents])), ex.expected_shares_cents);
  assert.equal(r.shares.reduce((a, s) => a + s.total_cents, 0), 10920);
  assert.equal(r.outstanding_cents, ex.expected_outstanding_cents);
  assert.deepEqual(new Set(r.requests.map((q) => q.contact_id)), new Set(["c_tanish", "c_aryan"]));
});

test("mismatched receipt and unknown contact are blocked", () => {
  const ds = load("seed-v1.json"), bad = { ...ds.receipts[0], total_cents: ds.receipts[0].total_cents + 100 };
  const a = { it_1: ["c_tanish"], it_2: ["c_aryan"], it_3: ["c_ashwin"], it_4: ["c_ashwin"] };
  assert.throws(() => E.prepareSplit({ receipt: bad, assignments: a, payerId: "c_ashwin", contacts: ds.contacts }), { code: "RECEIPT_MISMATCH" });
  assert.throws(() => E.prepareSplit({ receipt: ds.receipts[0], assignments: { ...a, it_1: ["c_bob"] }, payerId: "c_ashwin", contacts: ds.contacts }), { code: "AMBIGUOUS_CONTACT" });
});

test("largest remainder sums exactly", () => {
  assert.deepEqual(E.allocate(1000, [1, 1, 1]), [334, 333, 333]);
  assert.deepEqual(E.allocate(2520, [2200, 2800, 3400]), [660, 840, 1020]);
  assert.equal(E.allocate(7, [1, 1, 1, 1]).reduce((a, b) => a + b, 0), 7);
});

test("July and August have reconciled flows; balances are September snapshots", () => {
  const ds = load("seed-v1.json");
  for (const p of ["2026-07", "2026-08"]) {
    const v = E.moneyView(ds, p);
    assert.equal(v.categories.reduce((a, c) => a + c.total_cents, 0), v.flow.expenses_cents);
    assert.equal(v.flow.net_income_cents, v.flow.expenses_cents + v.flow.to_savings_cents + v.flow.to_investments_cents + v.flow.retained_cash_cents);
  }
});
