# Lana

Lana does money chores by text, by phone call, or in the app, so people get that time back. The model runs on the phone and code does every calculation. Nothing is sent or changed until you approve it.

Built at SpeedHacks on October 11, 2026 by Tanish, Aryan and Ashwin. The code still uses the working name Financial World Model (FWM).

**Demo video:** link added at submission.

## For judges

| Home | Budget | Receipts |
|:---:|:---:|:---:|
| <img src="docs/screenshots/home.png" width="240"> | <img src="docs/screenshots/budget.png" width="240"> | <img src="docs/screenshots/split.png" width="240"> |
| **Accounts** | **Chat** | **Call history** |
| <img src="docs/screenshots/accounts.png" width="240"> | <img src="docs/screenshots/chat.png" width="240"> | <img src="docs/screenshots/history.png" width="240"> |

These screenshots come from the iOS simulator running `main` (`Examples/LanaDemoApp`) with the synthetic September data. "Call · How did September go?" in the last one is a real phone call that came in through Dial and was answered by the app.

### What Lana does

- **Split a dinner bill.** Text Lana's number a receipt photo, or upload it in Receipts. Lana reads it on the device and you check each line. Then it computes exact shares: $109.20 becomes Tanish $36.40, Aryan $44.20 and Ashwin $28.60. Requests go out only after you approve them.
- **Review the month.** Ask "How did September go?" by text, by call or in chat. The answer is $4,800 in, $3,150 spent, $650 saved, $400 invested and $600 kept.
- **Find savings.** Ask "What can I swap to save money?" and Lana finds $150 a month. It skips swaps you turned down before. Ashwin rejected instant coffee, so it suggests whole beans.

### Time saved

| Chore | By hand | With Lana | Source |
|---|---|---|---|
| Split the dinner bill | 22 min | timed in the demo video | Both runs measured with the `/timer` stopwatch and logged to Keewano |
| Month review | 15 min | not measured yet | Estimate |
| Budget and swaps | 20 min | not measured yet | Estimate |

The Lana times include checking every receipt line and approving each request. One-time setup is pairing the phone with the relay, in Accounts → Messaging → Configure messaging relay, with a code from the relay.

### Partner tools

| Partner | What it does in Lana | Code |
|---|---|---|
| Dial | Lana's phone number, +1 314-464-9040. Texts and receipt photos arrive on Dial's event stream and replies go out through Dial. Calls use Dial Self-Hosted mode. Dial handles speech, the relay hands each turn to the paired phone, and Dial speaks the answer the phone's model wrote. | `relay/src/server.ts`, `relay/src/voice.ts` |
| Keewano | Records each swap decision (accepted or rejected) as an event and reads back which swap groups to stop suggesting. The `/timer` stopwatch logs measured chore times there for the time receipt. | `relay/src/keewano.ts` |
| Sparta | Tested the code that applies an approved phone-plan switch. Version 1 passed 1 of 4 cases, and 0 of 4 when the billing server failed. Version 2 passes 4 of 4 both ways. | `sparta/README.md`, `sparta/evidence/` |

### How a text or call is answered

```text
Your phone ──text/call──> Dial ──> relay (Node; no model, no money math) ──job──> iPhone running Lana
                                                                                   on-device model picks a tool
                                                                                   Swift engines compute the numbers
Your phone <──reply/voice── Dial <── relay <──────────────result──────────────────┘
```

The relay only moves messages. If no phone has Lana open, it texts "open Lana" and holds the job until a phone picks it up.

### Run it

- **App:** open `Examples/LanaDemoApp/LanaDemoApp.xcodeproj`, choose the LanaDemoApp scheme and run on iOS 26+. Conversational answers need Apple Intelligence.
- **Relay:** `cd relay && npm install && npm test`, then `npm start`. Copy `.env.example` to `.env` for Dial and Keewano keys.
- **Swift tests:** `swift test` and `swift test --package-path Packages/FWMCore`.
- **Sparta:** see `sparta/README.md`.

### Limits

- Bank data is a synthetic fixture plus CSV import. There are no live bank connections yet.
- Dial can't text US numbers until 10DLC registration clears, so the demo sends texts from the relay's `/phone` page. Calls work from a real phone.
- iOS doesn't let Lana answer in the background, which is why the relay nudges you to open it.
- The Budget screen labels its preference history as simulated. The live Keewano adapter is in the relay.

---

# Team notes: Financial World Model

An iPhone financial assistant that turns accounts, transactions, preferences, and receipts into useful answers and reviewable actions in one conversation. Built for SpeedHacks, October 11, 2026. Working name: **Financial World Model (FWM)**. Team: **Tanish, Aryan, and Ashwin**.

The product gives people time back by reducing the work of understanding their money, planning a budget, comparing alternatives, and splitting receipts. An on-device model interprets requests; deterministic engines compute every financial number. The user reviews changes before anything is committed or sent.

**Start here:** [Technical architecture and collaboration guide](docs/README.md). It covers ownership, shared interfaces, setup, tests, branches, commits, and merge procedures.

**Assign next work:** [Team task list](TODO.md) tracks suggested owners, dependencies, acceptance criteria, and version 1 follow-ups.

**AI branch handoff:** [Concrete Swift integration and verification](docs/AI_INTEGRATION.md) describes the canonical agent, adapter protocols, local receipt/voice APIs, and approval gate.

## Version 1

`main` now contains **Lana 1.0**: Ashwin's native screens connected to Tanish's local AI and Aryan's engines, providers and relay. Open `Examples/LanaDemoApp/LanaDemoApp.xcodeproj`, select **LanaDemoApp**, choose your signing team and an eligible iPhone, then Run. Requires iOS 26+ with Apple Intelligence ready for conversational inference. The app bundles its fixture; a Mac checkout is not needed at runtime.

Tap the centre orb for natural-language chat, PDF attachments, saved conversations and reviewed voice input. Split supports local receipt-image OCR followed by field/assignment review. Home, Budget and chat share the selected budget projection. Accounts provides real device authentication and optional HTTPS relay pairing. See [version 1 setup, verification and limits](docs/VERSION_1.md).

## What we are building

The current shared implementation follows the SRS v2 contracts referenced by `FWMCore`. The v2 document is in the team chat, not checked into this repository. The earlier broad SRS describes the product vision; it does not override the interfaces already shared here.

| Workflow | User request | App behavior |
|---|---|---|
| Understand my money | Where is my money going? | Show income, spending, savings, investments, retained cash, and net worth with evidence |
| Budget and swaps | Help me save more | Build a deterministic proposal and cheaper alternatives that respect preferences; approve before committing |
| Receipt and split | Split this dinner | Extract text locally, review items/contacts, reconcile the receipt, compute exact shares, preview requests before sending |

Supporting work includes local model routing, receipt OCR, on-device voice transcription, provider adapters, messaging relay, reminders, credential storage, and provider MFA support.

## Who is building what

| Owner | Primary scope |
|---|---|
| **Tanish** | On-device model and routing; scoped tool dispatch and approval gates; OCR/voice; vault/MFA; AI integration into the iOS host |
| **Aryan** | Aggregator adapters; messaging relay; money and split calculations; sponsor integrations |
| **Ashwin** | Demo data; three feature UIs; budget/swap logic; presentation |

`FWMCore` contracts are shared. The iOS host combines Tanish's AI infrastructure with Ashwin's feature views; host ownership does not transfer ownership of those views.

## Architecture

```text
App chat / reviewed voice / authenticated paired messaging
                          |
                iPhone-local model router
                          |
           Schema + scope + state + approval checks
                          |
                 Allowlisted FWMCore tools
                    /                \
        Deterministic engines    Local OCR / reviewed receipt
                    \                /
              Result + provenance + action proposal
                          |
             Chat / cards / drill-down share one result
                          |
           Human approval before commit or dispatch
```

The shared product plan uses **local inference, without a cloud LLM**. The relay carries jobs/messages and provider responses. It does not run inference or calculate money. Remote provider calls are separate from model processing. iOS background execution is constrained; the relay must handle an unavailable or foreground-required phone explicitly.

## Repository layout and status

| Path | Responsibility | Version 1 status |
|---|---|---|
| `Packages/FWMCore/` | Shared records/contracts; money and split engines; provider adapters (fixture, bank CSV import); golden tests | Merged on `main`; fixture-backed app; CSV adapter available as a library |
| `fixtures/` | Canonical and edge inputs, generator | Canonical seed plus expanded three-year world; Ashwin owns changes |
| `Examples/LanaDemoApp/`, `Packages/FWMFeatureUI/` | Integrated iPhone host, screens and composition adapters | Version 1 entry point |
| `relay/` | Dial inbox/outbox, job transport, reminders, Keewano | Merged; pairing and foreground worker wired in Accounts |
| `sparta/` | Sparta Worlds tests for the approved-action executor (phone-plan swap) | Merged; sandbox executor and recorded evidence |
| `docs/README.md` | Technical contracts and collaboration procedure | Shared documentation |
| Root `Package.swift`, `Sources/FinanceAI/`, `Tests/FinanceAITests/` | Tanish's reusable local AI module | Merged and connected to feature screens |
| `Examples/AIPlayground/` | AI-only SwiftUI test harness | Retained developer harness; use LanaDemoApp for the integrated product |

The AI module includes free-form Foundation Models chat with native finance/PDF tools, local conversation history, PDF text/scanned-page import, Vision OCR, local Speech transcription, confirmation orchestration, passcode-protected Keychain storage, and RFC-tested TOTP generation. Its harness uses the canonical v2 dataset and shared money/split engines. Foundation Models is the initial backend; **MLX is an option to evaluate, not an installed dependency**. A cloud routing prototype on that branch is unused and is not part of the agreed integrated architecture.

Update this status when components change. Distinguish implemented code, successful compilation, actual model inference, and physical-device verification.

## Run the checks

From the repository root:

```bash
swift test --package-path Packages/FWMCore
```

Also run:

```bash
swift test
swift run ai-diagnostics
```

Diagnostics identify whether routing used the local model or deterministic fallback. Passing fallback samples do **not** establish model quality. The AI package uses Swift tools 6.2+ and targets iOS 26+ / macOS 26+. `FWMCore` uses Swift tools 5.9+ and supports iOS 17+ / macOS 14+.

## Canonical demo numbers

Read these from the engines. Do not duplicate financial constants in prompts or UI.

| Result | Expected value |
|---|---:|
| September net income | $4,800.00 |
| Expenses | $3,150.00 |
| Transferred to savings | $650.00 |
| Transferred to investments | $400.00 |
| Retained cash | $600.00 |
| Net worth | $11,550.00 |
| Dinner total | $109.20 |
| Ashwin / Tanish / Aryan shares | $28.60 / $36.40 / $44.20 |
| Outstanding reimbursements to Ashwin | $80.60 |

## Shared conventions

- Store/calculate **integer USD cents**. Entering an account is positive; leaving is negative. Liability balances are positive amounts owed.
- Use `FWMJSON.encoder` / `FWMJSON.decoder` for snake_case wire JSON; keep stable IDs.
- Preserve `Provenance`: chat, card, and drill-down for a calculation share one `result_id`.
- The model proposes an allowlisted tool. It cannot calculate amounts, select authenticated identity, issue approval tokens, or read credentials.
- Bind human approval to action, user/conversation, payload, version, and expiry. Duplicate delivery must not execute twice.
- Keep fixture, sandbox, live, and cached modes visible; identify mocked actions.
- Keep secrets, recordings, personal receipts, and build artifacts out of Git.
- Use focused feature-branch commits and reviewed PRs; preserve history with merge commits. Direct `main` updates require explicit agreement, including shared setup and approved integration releases.

Read [the technical guide](docs/README.md) before changing shared contracts, fixtures, build settings, or another owner's files.

## Expanded synthetic fixtures

The isolated three-year world, canonical demo and October dinner live under
`fixtures/world-v1`. Read [the data handoff](docs/synthetic-data.md) for explicit
scenario loading, metric definitions, accounting assumptions and schema gaps.
Run `python3 -m tools.synthetic_data.validate` from the root to check the data
and existing Swift engine goldens. Legacy fixture files remain unchanged.
