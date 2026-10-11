#!/usr/bin/env python3
"""Generates the canonical FWM fixtures. Every total in SRS v2 pages 4-6 is asserted below.
Run: python3 fixtures/generate.py  (writes seed-v1.json and edge-v1.json)"""
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
TZ = "-07:00"  # America/Los_Angeles, PDT for all fixture dates
USER = "user_ashwin"

accounts = [
  {"account_id": "acct_checking", "institution": "Chase", "kind": "checking", "asset_or_liability": "asset", "opening_balance_cents": 280000, "balance_cents": 340000},
  {"account_id": "acct_savings", "institution": "Chase", "kind": "savings", "asset_or_liability": "asset", "opening_balance_cents": 800000, "balance_cents": 865000},
  {"account_id": "acct_brokerage", "institution": "Robinhood", "kind": "brokerage", "asset_or_liability": "asset", "opening_balance_cents": 1200000, "balance_cents": 1240000},
  {"account_id": "acct_card", "institution": "Capital One", "kind": "credit_card", "asset_or_liability": "liability", "opening_balance_cents": 90000, "balance_cents": 90000},
  {"account_id": "acct_student", "institution": "Sallie Mae", "kind": "student_loan", "asset_or_liability": "liability", "opening_balance_cents": 1200000, "balance_cents": 1200000},
]
for a in accounts:
  a.update({"user_id": USER, "as_of": f"2026-09-30T23:59:59{TZ}", "source_id": f"fixture:{a['account_id']}"})

# One month of checking activity. Expense lines per category sum to the SRS "Current" column.
MONTH_TEMPLATE = [
  # (day, merchant, category, cents)  negative = money leaving checking
  (1, "Mission Apartments", "Rent", -160000),
  (3, "Trader Joe's", "Groceries", -14250), (10, "Safeway", "Groceries", -12875), (17, "Trader Joe's", "Groceries", -11900), (24, "Costco", "Groceries", -10975),
  (5, "Tartine", "Dining", -4800), (12, "Nopa", "Dining", -9650), (19, "Chipotle", "Dining", -2875), (26, "Zuni Cafe", "Dining", -12675),
  (2, "Clipper", "Transport", -8600), (14, "Uber", "Transport", -4320), (22, "Lyft", "Transport", -3880), (28, "Shell", "Transport", -8200),
  (4, "Verizon", "Bills and subscriptions", -8500), (8, "PG&E", "Bills and subscriptions", -9200), (15, "Spotify", "Bills and subscriptions", -1199), (15, "Netflix", "Bills and subscriptions", -1549), (20, "Comcast", "Bills and subscriptions", -4552),
  (6, "Blue Bottle Coffee beans", "Other", -4000), (11, "Target", "Other", -6890), (18, "Amazon", "Other", -7245), (25, "Walgreens", "Other", -4100), (27, "Tide detergent", "Other", -2765),
]
CATEGORY_TARGETS = {"Rent": 160000, "Groceries": 50000, "Dining": 30000, "Transport": 25000, "Bills and subscriptions": 25000, "Other": 25000}

def month(y, m, tag):
  txns = []
  def add(day, merchant, category, cents, acct="acct_checking", pair=None):
    tid = f"txn_{tag}_{len(txns)+1:03d}"
    txns.append({"transaction_id": tid, "account_id": acct, "posted_at": f"{y}-{m:02d}-{day:02d}T12:00:00{TZ}",
                 "signed_amount_cents": cents, "merchant": merchant, "category": category, "pending": False,
                 "transfer_pair_id": pair, "source_id": f"fixture:{tid}"})
  add(15, "Acme Inc payroll", "Income", 240000)
  add(30, "Acme Inc payroll", "Income", 240000)
  for d, mer, cat, c in MONTH_TEMPLATE: add(d, mer, cat, c)
  add(16, "Transfer to savings", "Transfer", -65000, pair=f"pair_{tag}_sav"); add(16, "Transfer from checking", "Transfer", 65000, "acct_savings", pair=f"pair_{tag}_sav")
  add(16, "Transfer to brokerage", "Transfer", -40000, pair=f"pair_{tag}_inv"); add(16, "Transfer from checking", "Transfer", 40000, "acct_brokerage", pair=f"pair_{tag}_inv")
  return txns

txns = month(2026, 7, "jul") + month(2026, 8, "aug") + month(2026, 9, "sep")

# ---- assertions against SRS v2 ----
sep = [t for t in txns if t["posted_at"].startswith("2026-09")]
inc = sum(t["signed_amount_cents"] for t in sep if t["category"] == "Income")
exp = -sum(t["signed_amount_cents"] for t in sep if t["category"] not in ("Income", "Transfer"))
for cat, target in CATEGORY_TARGETS.items():
  got = -sum(t["signed_amount_cents"] for t in sep if t["category"] == cat)
  assert got == target, (cat, got, target)
assert inc == 480000 and exp == 315000, (inc, exp)
chk = sum(t["signed_amount_cents"] for t in sep if t["account_id"] == "acct_checking")
assert chk == 60000, chk  # checking 2,800 -> 3,400
assets = sum(a["balance_cents"] for a in accounts if a["asset_or_liability"] == "asset")
liab = sum(a["balance_cents"] for a in accounts if a["asset_or_liability"] == "liability")
assert (assets, liab, assets - liab) == (2445000, 1290000, 1155000)

receipt = {
  "receipt_id": "rcpt_dinner_1011", "merchant": "Lazy Bear (demo)", "date": "2026-10-11", "attachment_hash": None,
  "items": [
    {"item_id": "it_1", "description": "Short rib", "quantity": 1, "extended_price_cents": 2400, "ocr_confidence": 0.97},
    {"item_id": "it_2", "description": "Duck breast", "quantity": 1, "extended_price_cents": 3000, "ocr_confidence": 0.95},
    {"item_id": "it_3", "description": "Mushroom risotto", "quantity": 1, "extended_price_cents": 1800, "ocr_confidence": 0.96},
    {"item_id": "it_4", "description": "Burrata appetizer", "quantity": 1, "extended_price_cents": 1200, "ocr_confidence": 0.93},
  ],
  "subtotal_cents": 8400, "tax_cents": 840, "tip_cents": 1680, "total_cents": 10920,
}
assert sum(i["extended_price_cents"] for i in receipt["items"]) == receipt["subtotal_cents"]
assert receipt["subtotal_cents"] + receipt["tax_cents"] + receipt["tip_cents"] == receipt["total_cents"]

contacts = [
  {"contact_id": "c_ashwin", "reviewed_name": "Ashwin", "phone": "+15555550101", "venmo_handle": "@ashwin-demo", "is_self": True},
  {"contact_id": "c_tanish", "reviewed_name": "Tanish", "phone": "+15555550102", "venmo_handle": "@tanish-demo"},
  {"contact_id": "c_aryan", "reviewed_name": "Aryan", "phone": "+15555550103", "venmo_handle": "@aryan-demo"},
  {"contact_id": "c_tanya", "reviewed_name": "Tanya", "phone": "+15555550104", "venmo_handle": "@tanya-demo"},
]
# The voice instruction from SRS section 5, resolved to items. Golden output is asserted in the Swift tests.
split_example = {
  "receipt_id": "rcpt_dinner_1011", "payer_id": "c_ashwin", "tax_tip_rule": "proportional",
  "assignments": {"it_1": ["c_tanish"], "it_2": ["c_aryan"], "it_3": ["c_ashwin"], "it_4": ["c_ashwin", "c_tanish", "c_aryan"]},
  "expected_shares_cents": {"c_ashwin": 2860, "c_tanish": 3640, "c_aryan": 4420}, "expected_outstanding_cents": 8060,
}

user = {"user_id": USER, "display_name": "Ashwin", "timezone": "America/Los_Angeles", "currency": "USD",
        "brand_locks": ["oat_milk"], "dietary_rules": [], "savings_goal_cents": 15000, "preferences_version": 1}

seed = {"dataset_version": "seed-v1", "data_mode": "fixture", "as_of": f"2026-09-30T23:59:59{TZ}", "demo_clock": f"2026-10-11T18:00:00{TZ}",
        "user": user, "accounts": accounts, "transactions": txns, "receipts": [receipt], "contacts": contacts,
        "split_example": split_example, "category_targets_sep_cents": CATEGORY_TARGETS,
        "catalog": [], "_catalog_note": "Ashwin owns catalog + budget/swap fixtures (SRS section 4)."}
json.dump(seed, open(os.path.join(HERE, "seed-v1.json"), "w"), indent=1)

# Edge cases (DATA-02): refund, pending, matched transfer, card repayment. Kept outside the canonical totals.
E = lambda tid, acct, day, cents, mer, cat, pending=False, pair=None, refund_of=None: {"transaction_id": tid, "account_id": acct, "posted_at": f"2026-09-{day:02d}T12:00:00{TZ}", "signed_amount_cents": cents, "merchant": mer, "category": cat, "pending": pending, "transfer_pair_id": pair, "refund_of": refund_of, "source_id": f"fixture:{tid}"}
edge = {"dataset_version": "edge-v1", "data_mode": "fixture", "as_of": f"2026-09-30T23:59:59{TZ}", "user": user,
  "accounts": [dict(accounts[0], opening_balance_cents=100000, balance_cents=104000), dict(accounts[3], opening_balance_cents=20000, balance_cents=2000), dict(accounts[1], opening_balance_cents=0, balance_cents=10000)],
  "transactions": [
    E("e1", "acct_checking", 1, 50000, "Acme Inc payroll", "Income"),
    E("e2", "acct_card", 3, -12000, "REI", "Other"),                     # card purchase counts as spending
    E("e3", "acct_card", 9, 3000, "REI refund", "Other", refund_of="e2"),  # refund reduces Other
    E("e4", "acct_checking", 20, -27000, "Card payment", "Transfer", pair="p_card"),  # repayment: not spending
    E("e5", "acct_card", 20, 27000, "Payment received", "Transfer", pair="p_card"),
    E("e6", "acct_checking", 21, -10000, "Transfer to savings", "Transfer", pair="p_sav"),
    E("e7", "acct_savings", 21, 10000, "Transfer from checking", "Transfer", pair="p_sav"),
    E("e8", "acct_checking", 29, -6500, "Nopa", "Dining", pending=True),  # pending: excluded from posted totals
    E("e9", "acct_checking", 25, -9000, "Safeway", "Groceries"),
  ],
  "expected": {"net_income_cents": 50000, "expenses_cents": 18000, "to_savings_cents": 10000, "to_investments_cents": 0, "card_repayment_cents": 27000, "pending_cents": 6500,
               "categories_cents": {"Other": 9000, "Groceries": 9000}}}
json.dump(edge, open(os.path.join(HERE, "edge-v1.json"), "w"), indent=1)
print(f"seed-v1: {len(txns)} transactions, assets {assets}, liabilities {liab}, net worth {assets-liab}; edge-v1 written")
