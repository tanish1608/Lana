# Financial World Model

An iPhone financial assistant that turns accounts, transactions, preferences, and receipts into useful answers and reviewable actions in one conversation. Built for SpeedHacks, October 11, 2026. Working name: **Financial World Model (FWM)**. Team: **Tanish, Aryan, and Ashwin**.

The product gives people time back by reducing the work of understanding their money, planning a budget, comparing alternatives, and splitting receipts. An on-device model interprets requests; deterministic engines compute every financial number. The user reviews changes before anything is committed or sent.

**Start here:** [Technical architecture and collaboration guide](docs/README.md). It covers ownership, shared interfaces, setup, tests, branches, commits, and merge procedures.

**AI branch handoff:** [Concrete Swift integration and verification](docs/AI_INTEGRATION.md) describes the canonical agent, adapter protocols, local receipt/voice APIs, and approval gate.

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

| Path | Responsibility | Status at documentation baseline |
|---|---|---|
| `Packages/FWMCore/` | Shared records/contracts; money and split engines; golden tests | Implemented on `main` |
| `fixtures/` | Canonical and edge inputs, generator | Drafted on `main`; Ashwin owns subsequent changes |
| `ios/` | Integrated iPhone host and feature screens | Intended app location; not yet present at this baseline |
| `relay/` | Dial inbox/outbox, job transport, reminders, Keewano | Aryan's lane; not yet present at this baseline |
| `docs/README.md` | Technical contracts and collaboration procedure | Shared documentation |
| Root `Package.swift`, `Sources/FinanceAI/`, `Tests/FinanceAITests/` | Tanish's reusable local AI module | On `codex/on-device-ai`; integrated with `FWMCore` |
| `Examples/AIPlayground/` | AI-only SwiftUI test harness | Development harness on AI branch; separate from final feature screens |

The AI branch includes Apple Foundation Models routing, Vision OCR, local Speech transcription, confirmation orchestration, passcode-protected Keychain storage, and RFC-tested TOTP generation. Its harness now uses the canonical v2 dataset and shared money/split engines. Foundation Models is the initial backend; **MLX is an option to evaluate, not an installed dependency**. A cloud routing prototype on that branch is unused and is not part of the agreed integrated architecture.

Update this baseline when components land. Distinguish implemented code, successful compilation, actual model inference, and physical-device verification.

## Run the checks

From the repository root:

```bash
swift test --package-path Packages/FWMCore
```

On the AI branch, also run:

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
- Use focused feature-branch commits and reviewed PRs; preserve history with merge commits. Direct `main` edits are reserved for explicitly agreed shared setup such as these docs.

Read [the technical guide](docs/README.md) before changing shared contracts, fixtures, build settings, or another owner's files.
