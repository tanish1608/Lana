# Synthetic financial data specification

The user's complete delivery request authorizes continuous execution of all five
stages. This scoped specification applies only to synthetic data; it does not
implement the team's budget, provider, messaging, or application engines.

1. [x] Publish supplementary schema, manifest, biography and current snapshot.
2. [x] Publish full-world September ledger and derived summary.
3. [x] Publish isolated canonical September and October dinner evidence.
4. [x] Export 36 completed months, exact activity and reconciled statements.
5. [x] Add documents, edge expectations, validation and handoff; commit data branch.

## Contracts

Leave existing FWMCore sources and legacy fixture goldens unchanged. New files
use snake_case, integer USD cents, Decimal string quantities/prices, deterministic
IDs, fixed seed, explicit synthetic flags and source references. Supplemental
account metadata and valuations are behind an explicit scenario loader. Historical
core adapters decode as Dataset, but the existing MoneyEngine does not support
debt principal, investment performance or property; expanded views must use the
derived supplemental summaries, never a legacy MoneyView as full-world wealth.

## Accounting and validation

Posted consumption recognizes card purchases and offsets linked refunds. Card
payments and principal payments have equal linked cash/liability legs. All owned
asset transfers have equal linked cash legs. Portfolio cash changes come from
trade/funding/dividend/settlement activity, holdings from fills, and valuations
from synthetic marks. Monthly statements reference the same ledger. Separate
October activity and prospective/user-reported actions from completed months.

Reconcile every account monthly, replay holdings with FIFO cents basis, replay
prediction cash/positions, amortize debts, compare property ownership treatment,
and derive consolidated wealth without adding cash/holdings to account equity
again. Validate references, schema, dates, scenario isolation, savings evidence,
receipt allocation and reproducibility. Run existing Swift goldens and added
adapter/split tests. Negative tests must prove accounting faults are rejected.

## Failure and output policy

No network or secrets in generation/loading/validation. CLI inputs are bounded
scenario/period choices. Write deterministic files atomically and reject unknown
scenario IDs. A failed invariant exits nonzero with record context. Stage export
leaves a coherent manifest for the available files. No changes to other lanes.
PDF rendering is an optional separately installed local dependency; generation
and financial checks use Python's standard library. Report which checks ran.
