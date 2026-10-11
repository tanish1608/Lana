# Financial World Model (SpeedHacks, Oct 11 2026)

A phone-based financial assistant. You text it, an on-device model picks a tool, and deterministic engines on the phone compute every number. Spec: SRS v2 (in the team chat). Team: Ashwin, Tanish, Aryan.

## Layout

| Path | Owner | What |
|---|---|---|
| `ios/` | Tanish | SwiftUI app, MLX model and router, OCR/speech, vault/MFA |
| `Packages/FWMCore/` | shared | Swift package the app imports. Contracts (`MessageEnvelope`, `AgentResult`, `ToolError`, `ToolCall`), `MoneyEngine` and `SplitEngine` (Aryan), budget/swap engine (Ashwin, to add) |
| `relay/` | Aryan | TypeScript relay: Dial inbox/outbox, job queue the phone pulls from, reminders, Keewano swap memory. No cloud LLM. |
| `fixtures/` | Ashwin (drafted by Aryan) | `seed-v1.json` (canonical persona) and `edge-v1.json` (refund, pending, transfers, card repayment). `generate.py` asserts every SRS total. |

## Check the numbers

```bash
cd Packages/FWMCore && swift test
```

The tests pin the SRS golden values: a $4,800 September flow ($3,150 expenses, $650 to savings, $400 invested, $600 retained), $11,550 net worth, and dinner shares of $28.60, $36.40 and $44.20 ($80.60 outstanding).

## Conventions

- Integer USD cents everywhere. Snake_case JSON on the wire (`FWMJSON.encoder` / `FWMJSON.decoder`).
- Money entering an account is positive, money leaving is negative. Liability balances are positive amounts owed.
- Every result carries `Provenance` (result_id, dataset_version, data_mode, as_of, source_ids, engine_version). Chat, card and drill-down share one result_id.
- Errors use `ToolError` codes: AUTH_REQUIRED, STALE_DATA, AMBIGUOUS_CONTACT, RECEIPT_MISMATCH, PROVIDER_UNAVAILABLE, NEEDS_FOREGROUND, INVALID_ARGUMENTS, UNKNOWN_TOOL.

## Using FWMCore from the app

In Xcode: File → Add Package Dependencies → Add Local… → `Packages/FWMCore`. Then:

```swift
import FWMCore
let ds = try Dataset.load(from: Bundle.main.url(forResource: "seed-v1", withExtension: "json")!)
let view = try MoneyEngine.moneyView(ds, period: "2026-09")
let split = try SplitEngine.prepareSplit(receipt: ds.receipts![0], assignments: [...], payerId: "c_ashwin", contacts: ds.contacts!)
```
