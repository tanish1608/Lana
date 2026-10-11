# Actual synthetic fixture validation

Run October 11, 2026 on the final fixture contents.

- `python3 -m tools.synthetic_data.validate`: PASS.
- Existing and new Swift checks: **13 passed, 0 failed**.
- 36 completed months, 3,353 ledger transactions and 357 account statements.
- 116 long-only security trades and 358 prediction-market events.
- Nine independent corruption tests rejected the intended accounting faults.
- 25 generated files, including manifests, reproduced from seed 261011; complete
  inventory matches the checked-in bytes with versioned static asset inputs.
- Seven PDFs independently rendered again: identical bytes, 7/7, using the same
  ReportLab/Pillow runtime. Additional June 2024 savings statement rendering passed.
- All nine PDF pages and the receipt PNG visually inspected; no clipping/overlap.
- Scenario loaders exercised for current world, historical April 2024, canonical
  September and October dinner. `git diff --check` passed.
- Original FWMCore source files and legacy fixture/generator files have no changes.

The schema/accounting audit checks references, exact cents/Decimal arithmetic,
chronological balances, statement/ledger equality, transfer/card treatment, FIFO
lots, prediction cash/reservations/marks/settlements, amortization, property equity,
consolidation, budget evidence, receipt/reimbursements, isolated scenarios and
reproducibility. Edge fixtures for approvals/delivery/reminders are product
contracts, not verified app/network behavior. No provider, OCR, voice, Keewano or
payment integration is claimed tested.

```json
{
  "current_net_worth_cents": 24524330,
  "invariant_assertions": 1515081,
  "invariant_groups": 155,
  "market_events": 358,
  "months": 36,
  "negative_tests": 9,
  "reproduced_files": 25,
  "security_trades": 116,
  "september_net_worth_cents": 24743532,
  "statements": 357,
  "status": "PASS",
  "swift": "passed (existing engines + synthetic fixture contract tests)",
  "transactions": 3353
}
```
