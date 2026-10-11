# Synthetic data handoff

Everything under `fixtures/world-v1` is fictional demonstration data. Accounts
named Chase, Capital One, Robinhood, Kalshi and Polymarket are not provider
connections. Prices, outcomes and product offers are synthetic. No API keys,
wallet addresses, usable account numbers or real contact destinations are used.
The original `seed-v1.json`, `edge-v1.json`, `generate.py` and FWMCore source files
are preserved unchanged.

## Start loading

From the repository root, select exactly one scenario:

```sh
python3 -m tools.synthetic_data.load --scenario full_financial_world
python3 -m tools.synthetic_data.load --scenario full_financial_world --period 2026-09
python3 -m tools.synthetic_data.load --scenario full_financial_world --period 2024-04
python3 -m tools.synthetic_data.load --scenario canonical_demo
python3 -m tools.synthetic_data.load --scenario dinner_2026_10_11
```

The loader returns only the selected scenario/period. Unknown scenario IDs,
noncompleted months and unsupported canonical periods fail. The full scenario
returns its October 11 snapshot unless a completed period is selected. October
activity belongs only to `snapshot.json.october_activity`, not the history ledger.
Python 3.10+ with IANA timezone data is sufficient for generation and validation.
Run as a module from the repository root; direct script execution of the loader
is not the supported entrypoint.

```sh
python3 -m tools.synthetic_data.generate --stage full
python3 -m tools.synthetic_data.validate
```

The second command validates the complete fixture set, corrupts nine disposable
copies to prove rejection, compares two independent deterministic regenerations
with the checked-in output, and runs the 13 FWMCore tests. It uses no provider
connections. Swift must be installed; `--skip-swift` explicitly requests data-only
checks and reports the skip. The fixed seed is `261011`, version
`synthetic-world-v1`, currency USD, timezone America/Los_Angeles and demo clock
October 11, 2026 at **21:00 PDT**. Completed coverage is October 1, 2023 through
September 30, 2026. Offset generation handles PST/PDT rather than forcing PDT.

## Scenario contracts

| Scenario | Purpose and entrypoint | Consumer |
|---|---|---|
| `canonical_demo` | `canonical_demo/dataset.json`, compact September only | Existing MoneyEngine regression and original demo |
| `full_financial_world` | `full_financial_world/snapshot.json` and `september.json` | Primary expanded UI; supplemental summaries/adapters |
| `dinner_2026_10_11` | `dinner_2026_10_11/scenario.json` | Receipt, SplitEngine, handoff and reminder examples |
| `edge_cases` | `edge-cases.json`, adversarial inputs and expected outcomes | Separate tests; never add to default ledgers |

The `canonical_demo/manifest.json` and `full_financial_world/manifest.json` bind
each scenario to its own file set and explicitly prohibit ledger merging.
`manifest.json` inventories every fixture/asset with hash, schema, scenario and
consumer. Its file inventory is authoritative. `world.schema.json` is a standard
JSON Schema document. The dependency-free validator implements the schema's used
keywords (`$ref`, `allOf`, `anyOf`, type, required, const, enum, pattern, properties,
items and boolean schemas); it is not a general JSON Schema implementation.

`full_financial_world/core-september.json` deliberately preserves the existing
**Dataset decoder** shape. Its investment account balances represent cash and
collateral, not total account wealth. Do not pass it to MoneyEngine to display
expanded spending/net worth. That engine lacks debt-principal classification,
portfolio valuation and property treatment and would misclassify trade cash and
loan payments. Use the supplemental summary/snapshot below. The adapter is a
migration seam, not a claim that the legacy MoneyEngine supports new domains.
The added Swift test decodes it and reconciles every cash/liability balance.

The isolated canonical scenario retains the original exact figures:
$4,800 income, $3,150 consumption, $650 savings, $400 investment funding, $600
retained checking cash, and $11,550 net worth. Its expenses are checking-funded;
debt stays unchanged, and there are no investment returns. The two scenarios
must never share or sum balances. Expanded-world wealth must never display
$11,550.

## Full scenario files

Paths below are relative to `fixtures/world-v1/`.

| File | Contents and source of truth |
|---|---|
| `profile.json` | Morgan Cedar's biography, account roles, goals, acquisition and synthetic assumptions |
| `full_financial_world/accounts.json` | Stable account, merchant and instrument identities, opening boundaries |
| `full_financial_world/ledger.json` | 3,353 posted ledger records for 36 months; primary cash/liability activity |
| `full_financial_world/september.json` | Exact September slice, summary and account statements |
| `full_financial_world/snapshot.json` | October 11 balances derived by applying the separate October activity to September; upcoming obligations |
| `full_financial_world/statements.json` | 357 machine statements across banks, cards, investment cash accounts and loans; no pre-opening statements |
| `full_financial_world/summaries.json` | 36 derived monthly summaries with categories, cash flows, balances, utilization, valuation and transaction evidence IDs |
| `full_financial_world/annual.json` | Calendar-year rollups; 2023 and 2026 visibly partial |
| `full_financial_world/portfolio.json` | 116 stock/ETF trades, FIFO lots, 144 position marks and 36 account-equity reports |
| `full_financial_world/prediction-markets.json` | Fictional markets, 358 events, unresolved marks, monthly cash/collateral, reserved orders, equity and funding-adjusted returns |
| `full_financial_world/property-debt.json` | Acquisition, 36 illiquid value estimates, mortgage and student amortization |
| `full_financial_world/events.json` | Chart narratives with ledger evidence and income-change references |
| `full_financial_world/swaps.json` | Seven supported savings opportunities, product itemization, exclusions, decision history, normalized Keewano fixture and projected plan |
| `full_financial_world/recurring.json` | Merchant-matched recurring obligations and video cancellation |
| `canonical_demo/swaps.json` | Isolated original $150 projection, with synthetic itemization of bundled compact purchases |
| `dinner_2026_10_11/` | OCR text, reviewed extraction, transcript, aliases, alternative state snapshots, PNG/SVG receipt |
| `documents/` | Seven neutral PDF examples and separately declared expected extraction fields |
| `edge-cases.json` | 18 edge contracts; one ingestion dataset is exercised by the real MoneyEngine |

Derived summaries, statements and narratives reference the ledger/trade/mark IDs;
never treat them as additional wealth or additional transactions. The generator
replays history to derive the current snapshot even in an early export stage.
`--stage snapshot` exports just profile/September/current files before history
files become available; `--stage demo` adds canonical/dinner/swaps; `--stage full`
exports all history. Staging was published in focused commits before final history.
Use a fresh `--output` directory for partial-stage exports; it does not delete
files from previous full exports.

## Biography and accounting policy

Morgan is a fictional 32-year-old software engineer with net pay of $7,200,
then $8,200 from July 2024, then $9,000 from July 2025. Pay arrives twice monthly.
Morgan owns 100% of a $360,000 condo acquired before coverage and bears 100% of
its mortgage. Opening loan principal is a declared synthetic boundary, not a
reconstruction of pre-October 2023 history. This is a home, not a rental.
Taxes, insurance and HOA are paid directly monthly; escrow is zero. Annual
travel is an upcoming projected expense, not an additional insurance debit.

Chase handles payroll, housing and investment funding. Chase savings holds the
emergency fund. The two Capital One accounts opened July 2024 for bill and
annual-expense envelopes. Morgan intentionally accumulates substantial checking
cash for a future home upgrade; this is a visible opportunity in the money view,
not an omitted asset. No small manually tracked assets are added to pad wealth.

Card purchases are consumption when posted. Liability charges are negative
activity, payments/refunds positive, and balances owed are positive. Pay the
previous statement balance in the following month. December 2024 deliberately
leaves $100 unpaid; January charges synthetic 2% interest on that residual and a
$15 fee. This is a deliberately simple **fictional policy**, not issuer terms.
Interest and fees reconcile to their separate statement components. The coat
refund in February 2025 references its original purchase and merchant identity.

Mortgage interest is 5%/12 of opening principal, rounded half up to cents; monthly
cash payment is $1,600. Student interest is 4.5%/12; regular payment is $220, plus
$100 additional principal from July 2025. Principal has linked bank/liability
legs. Interest is consumption; principal is not. All transfers have equal,
opposite linked legs. Investment withdrawals and reimbursements are separate
kinds; neither becomes ordinary payroll income. Market buy fees are capitalized
in position basis and investment performance, not household consumption.

Robinhood is long-only VTI, VXUS, BND and AAPL plus cash, with synthetic prices,
FIFO basis, zero trade fees and quarterly synthetic dividends. Initial positions
are bought from the documented opening cash in October 2023, so quantities are
fully derivable. Every sale is owned. Return is equity change less net funding;
no tax forms, margin, options or shorts are modeled.

Kalshi uses USD cash, a 20-cent fee per buy, zero settlement fee and fictional
binary contracts. Polymarket uses `SYNTHETIC_USDC` collateral at a declared
synthetic $1/unit, with collateral quantity explicitly separate from USD value;
no blockchain/wallet is modeled. Available plus reserved cash equals total cash.
Cash plus open marks equals equity. Reserved order funds and position basis are
never added again. Settlements return payout; profit subtracts the original
basis and fees. Fictional YES and NO outcomes provide both gains and resolved
losses. September sports positions remain unresolved. Polymarket's September
sports price mark is dated August 31 (the market opened August 20) and explicitly stale; other marks use period end.

## Metric definitions and September results

| Metric | Definition | September full-world result |
|---|---|---:|
| Income | Net payroll plus savings interest; excludes dividends, withdrawals and reimbursements | $9,040.97 |
| Consumption spending | Posted bank/card consumption, debt/card interest, fees, less linked refunds | $3,421.36 |
| Savings contributions | Net deposits into designated savings via linked transfers | $500.00 |
| Investment funding | Outgoing bank funding of Robinhood and prediction accounts | $730.00 |
| Debt principal | Mortgage/student principal; excludes card payments | $771.08 |
| Card payments | Cash used to reduce cards; already recognized purchases are not counted again | $2,410.68 |
| Accrual allocation remainder | Income + reimbursements - consumption - debt principal - savings - investment funding + withdrawals | $3,768.53 |
| Checking cash retained | Actual change across both checking accounts; timing differs from accrual purchases | $2,642.33 |
| Bank cash change | Actual posted change across checking and savings | $3,183.30 |
| Assets | Bank cash + portfolio account equity + market account equity + attributable property value, each once | $524,875.92 |
| Liabilities | Mortgage + student principal + cards owed | $277,440.60 |
| Net worth | Assets minus liabilities | $247,435.32 |

October 11 net worth is **$245,243.30** after separate October housing, debt,
bills, card payments, grocery purchase and dinner. The next payroll on October 15
is beyond the demo clock and is not included. Current available-to-spend is posted
checking cash less a $1,241.99 reserve for remaining October savings/investment
contributions and the music subscription. It excludes savings, securities, prediction positions and property.
This is a documented demo liquidity policy, not a financial recommendation.

`total_bank_cash_outflow_cents` includes transfers, card payments and principal.
It differs from consumption because credit purchases can precede cash payment.
`net_checking_cash_retained_cents` is a cash-flow change, not an investment
return. `accrual_allocation_remainder_cents` is intentionally separately named;
do not show it as actual retained cash. Property gross value is the entire
estimated home value; attributable value applies ownership; equity subtracts
attributable debt. Unrealized P/L is mark less remaining basis; realized P/L is
sale/settlement proceeds less removed basis/fees. Illiquid property estimates
and unresolved positions never increase liquid available funds.

## Budget and receipt handoff

The seven projected savings remain $36 pantry, $24 detergent, $20 beans,
$20 phone, $20 dining, $10 transport and $20 other: **$150** total. Full-world
purchase evidence references incurred September transactions and exact product
quantities/costs. Dining and discretionary alternatives compare actual two-
purchase bundles. Canonical grocery evidence is a declared portion of a bundled
merchant purchase. Oat milk stays; phone coverage is assumed comparable and
required; rejected instant coffee ($30) is excluded. Accepted different beans
save $20. All prices and eligibility are synthetic assumptions. The normalized
Keewano result proves fixture normalization and preference change, not a live
integration. Adoption updates only `projected` plan state, never the ledger.

The dinner receipt is $84 items + $8.40 tax + $16.80 tip = $109.20. Existing
SplitEngine produces Ashwin $28.60, Tanish $36.40 and Aryan $44.20, leaving $80.60
owed to the payer. The label Ashwin refers to Morgan's synthetic self alias in
this dinner example. All aliases are unverified and have no real phone/handle.
`oct_dinner_purchase` is the only linked expense; upload/extraction adds none.

Default dinner state is `reviewed`. State snapshots are alternative **simulated**
examples, not a completed execution timeline. Opening a payment app is a handoff;
a sent request is not settlement; a manual report is user-reported evidence.
The hypothetical verified-settlement branch has a separately synthetic evidence
record and is not applied to observed balances. Next-day reminders are per
participant, only active after sending, and cancel after reported payment,
dispute or verified settlement. No requests/reminders are sent by these tools.
Duplicate approval and unknown delivery are contract expectations for the
app/relay team, not claims of verified delivery behavior.

## Statements and rendering

Seven checked-in neutral PDFs cover normal banking (November 2023), a card
refund (February 2025), interest/fees (January 2025), recent banking (September
2026), Robinhood, Kalshi and Polymarket. All pages prominently identify synthetic
data, use no issuer branding/account numbers, and contain source references.
The expected extraction fixture is supplied separately with `parser_tested=false`.
Visual rendering inspection does not establish OCR/parser performance.

Install optional local rendering dependencies in your own environment:

```sh
python3 -m pip install -r tools/synthetic_data/requirements-render.txt
python3 -m tools.synthetic_data.render
python3 -m tools.synthetic_data.render --account chase_savings --period 2024-06 --output /tmp/fwm-statements
```

Default rendering also creates the receipt PNG and SVG. Exact financial output
needs no third-party Python dependency. PDF generation uses invariant timestamps;
identical renderer/runtime versions reproduce PDF bytes. Receipt rendering uses
local Menlo when present and Pillow's fallback otherwise, so pixels can differ
between platforms. No downloaded fonts/assets or provider access is required.

## Coverage and known gaps

| Domain | Supported | Simplified or absent |
|---|---|---|
| Banking | Four stable accounts, openings, cash reconciliations, monthly statements, interest and transfers | No overdraft, FX or live feeds |
| Cards | Two cards, purchases/refund/payments, limits/utilization, minimum/due dates, one finance-charge month | Calendar statements; fictional interest policy, no real issuer APR mechanics |
| Investments | Cash, four instruments, buys/sells, FIFO lots, dividends, monthly marks and contribution-adjusted return | Synthetic market paths, no corporate actions/tax documents/margin/options |
| Prediction markets | USD/collateral, buys, order reservation, open marks, gains/losses, settlements, withdrawals and stale example | Fictional binary mechanics/outcomes; no actual exchange/chain/limit-book integration |
| Property | Acquisition, monthly provenance, uncertainty, ownership and equity, fractional-ownership edge | One home; no rentals, appraisal service or co-owner payment accounting |
| Debt | Mortgage/student amortization, principal/interest, extra student payments and card balances | Monthly rate approximation, no escrow, tax deductibility or loan servicing rules |
| Money UI | Income/category/merchant drilldown, recurring obligations, cash allocation, net worth history, liquid/illiquid split and upcoming expenses | Current FWMCore needs a domain-aware adapter for expanded money views |
| Budget/swaps | Incurring evidence, unit sizes, price assumptions, preference history, exact $150 projected plan | No budget engine duplication or live Keewano call |
| Receipt | Structured/reviewed/OCR evidence, code asset, exact split and October link | No actual OCR/speech/payment/reminder delivery verified |
| Edge cases | 18 isolated expectations, actual ingestion/split engine checks and nine corruption tests | Approval, transport, reminder behavior remains app/relay implementation work |

The legacy SplitEngine tolerates one cent of mismatch. The mismatch error fixture
uses two cents and is tested against that contract. Exact default receipt totals
are enforced independently. A one-cent input may produce share totals differing
from the supplied receipt total in the legacy engine; strict reconciliation at
review remains a consumer gap, not changed silently here.

## Team handoff

- **Claude:** select `full_financial_world`, render `snapshot.json` for the fixed
  clock and `summaries.json` for completed-month charts. Use ledger/category
  evidence for drilldown and keep `canonical_demo` as an explicit demo switch.
  Prefer bank cash, portfolio equity, market equity and property components over
  a sum of `core-september` account balances. Do not add holdings again.
- **Tanish:** inject the fixed clock; decode the core adapter only at the existing
  contract boundary. Dinner aliases are simulated, so require a real reviewed
  contact before any live handoff. Keep reviewed receipt and provenance together.
- **Aryan:** adapt supplemental activity kinds, position equity and property
  records into future financial tools. Existing MoneyEngine/SplitEngine were
  reused for compatible canonical/edge/receipt tests. Synthetic reminder and
  request states describe expected product behavior, not verified integration.

No other owner's production engine or shared contract was edited.
