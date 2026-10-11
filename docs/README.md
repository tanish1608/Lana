# Technical architecture and collaboration guide

Read this with the [project overview](../README.md). It records the shared interfaces, lane ownership, and integration procedure for Tanish, Aryan, and Ashwin. It does not impose a build schedule.

## Ownership and handoffs

| Area | Owner | Handoff |
|---|---|---|
| Local model, routing, tool dispatch | Tanish | Typed proposal or clarification/error; authenticated scope and approval checks |
| OCR / voice | Tanish | Original evidence, confidence, reviewed receipt fields/transcripts; explicit local-processing unavailability |
| Vault / MFA helpers | Tanish | Device-bound secrets and user-presence checks; provider challenge handoff |
| Aggregator/provider adapters | Aryan | User-scoped normalized records, provider status, and provenance |
| Messaging relay / sponsor integrations | Aryan | Authenticated jobs, responses, dedupe/retry/foreground semantics |
| Money / split engines | Aryan | `MoneyView`, `SplitResult`, canonical calculations and golden tests |
| Demo fixtures | Ashwin | Stable inputs/IDs; generator and expected values changed together |
| Budget / swaps | Ashwin | Deterministic proposals compatible with shared tool names and preferences |
| Three feature UIs / presentation | Ashwin | Money, budget/swaps, receipt/split screens displaying engine results |
| iOS composition / AI harness | Tanish with Ashwin | Dependency injection and AI entry points, without duplicating feature logic |
| `FWMCore` contracts | Shared; coordinate with Aryan on existing files | Backward-compatible additions or an agreed migration with consumer tests |

An owner is the first reviewer, not an exclusive editor. Coordinate broad cross-lane edits. Do not rename shared types, move another person's files, or regenerate fixtures incidentally.

## Sources of truth

1. `Packages/FWMCore/Sources/FWMCore/Contracts.swift`: envelopes, tool allowlist, errors, provenance.
2. `Packages/FWMCore/Sources/FWMCore/Dataset.swift`: normalized financial, receipt, contact, and preference records.
3. `fixtures/seed-v1.json`, `fixtures/edge-v1.json`, `fixtures/generate.py`: reproducible inputs.
4. `Packages/FWMCore/Tests/FWMCoreTests/EngineTests.swift`: canonical values and edge behavior.
5. These docs: ownership and integration procedure.

The code references SRS v2 in team chat; that document is not checked in. The older broad SRS and initial AI cancellation harness do not replace these shared interfaces. Describe mismatches and agree on behavior before changing contracts; do not invent unseen v2 requirements.

## Runtime flow

1. Accept app context or an authenticated, paired relay envelope.
2. Extract/transcribe attachments locally when needed; keep reviewable source evidence.
3. Route with local AI or a visibly labeled deterministic fallback.
4. Validate tool schema, bounds, object ownership, user scope, and state/version.
5. Invoke a deterministic engine or prepare an action proposal.
6. Render the same result/provenance in chat, card, and drill-down.
7. Review and authorize mutations or outbound requests explicitly.

The integrated product uses **no cloud LLM**. Relay jobs/provider calls are distinct from inference. Do not assume the phone can run continuously in the background; report `NEEDS_FOREGROUND` when appropriate. Do not turn on a prototype cloud route when the local model is unavailable.

Apple Foundation Models is Tanish's initial backend. Check availability on the actual device: eligible hardware, supported OS/language/region, Apple Intelligence enabled, model downloaded. MLX remains an alternative to evaluate behind the same router interface; it is not currently installed or verified.

## Data conventions

- All money arithmetic uses integer **USD cents**, not `Double`.
- Inflows are positive and outflows negative. Liability balances are positive amounts owed.
- Keep refunds, pending records, transfers, and card repayments identifiable. Let `MoneyEngine` classify them; do not count them separately in UI/model code.
- Use the user's timezone for period boundaries. Canonical fixture timezone: `America/Los_Angeles`; money month: `2026-09`.
- Use `FWMJSON` for snake_case JSON. Preserve stable IDs, source IDs, timestamps, `dataset_version`, and `preferences_version`.
- Provider adapters scope records before calling an engine. Normalized structs do not enforce authorization themselves.
- An attachment reference is not permission to fetch an arbitrary URL from a prompt/model.

Preserve all `Provenance` fields: `result_id`, `dataset_version`, `data_mode`, `as_of`, `currency`, `source_ids`, `evidence_ids`, `engine_version`. Modes: `fixture`, `sandbox`, `live`, `cached`. A calculation's chat answer, card, and drill-down share the same result ID and amounts.

## Messaging contracts

`MessageEnvelope`: `event_id`, `conversation_id`, `paired_user_id`, `channel`, `received_at`, optional `text`, `attachments`. The relay supplies identity from authenticated pairing. Model content cannot override it. Channels (`app`, `sms`, `imessage`) describe transport; a channel label does not prove its integration is implemented.

`AgentResult`: `job_id`, `reply_text`, optional `card_id`, `proposed_action_id`, `provenance`. Financial responses preserve the actual engine provenance. Use event/job IDs to deduplicate and trace requests without logging raw financial content or secrets.

`FWMCore.RelayClient` and [relay/README.md](../relay/README.md) define pairing, endpoints, approvals, leases, retry/deduplication and foreground semantics. The iOS host uses that client and stores the pairing in Keychain.

## Canonical tools

| Tool | Arguments | Owner | Validation / review |
|---|---|---|---|
| `get_money_view` | `period`, optional `account_filter` | Aryan | Read-only; account IDs within authenticated scope |
| `propose_budget` | `period`, `extra_savings_cents` | Ashwin | Nonnegative requested savings; proposal only |
| `get_swap_memory` | `user_id`, `eligible_groups` | Aryan | Dispatcher binds/validates user ID; model cannot select another user |
| `suggest_swaps` | `budget_id`, `preferences_version` | Ashwin | Owned budget, current preferences |
| `extract_receipt` | `local_attachment_id` | Tanish | Local owned attachment; OCR draft reviewed |
| `prepare_split` | `receipt_id`, item-to-contact `assignments`, `payer_id` | Aryan | Owned/reconciled receipt, reviewed contacts |
| `commit_budget_plan` | `action_id`, `approval_token` | Ashwin + Tanish | Mutation: human approval and matching state/version |
| `dispatch_requests` | `action_id`, `approval_token` | Aryan + Tanish | Outbound requests: preview recipients/amounts, then approve |

Model proposal example:

```json
{"tool":"get_money_view","arguments":{"period":"2026-09"}}
```

`ToolCall.parse` is a shared reference parser, **not authorization**. The dispatcher adds stricter domain validation: valid calendar month, integer bounds, known/owned IDs, valid contact assignments, current state. Model-supplied `user_id`, `action_id`, or `approval_token` never grants execution rights. The host supplies identity and human approvals separately.

| `ToolError` code | Caller behavior |
|---|---|
| `AUTH_REQUIRED` | Ask for authentication; do not loop retries |
| `STALE_DATA` | Refresh/recompute; changed terms need fresh approval |
| `AMBIGUOUS_CONTACT` | Let the user select a reviewed contact |
| `RECEIPT_MISMATCH` | Show evidence and request receipt correction |
| `PROVIDER_UNAVAILABLE` | Explain failure; retry only when marked retryable |
| `NEEDS_FOREGROUND` | Ask the user to open the app |
| `INVALID_ARGUMENTS` | Clarify/correct input |
| `UNKNOWN_TOOL` | Explain supported tools; never execute arbitrary names |

Do not create another public wire envelope/error enum in a feature folder. Internal AI types may exist, but bridge to `FWMCore` at app/relay boundaries.

## Approval, privacy, and MFA

- Bound model input. Query engines for compact results instead of sending all transaction history to the model.
- Treat text, OCR, receipts, and provider content as data; they cannot change tool permissions.
- Receipt fields are drafts until reviewed. Preserve raw OCR/confidence and reconcile amounts before split/dispatch.
- Speech sets `requiresOnDeviceRecognition` and verifies support. Unsupported local recognition asks for typed input; no silent upload. Delete temporary recordings after success, failure, and cancellation.
- App-side secrets use passcode-required, device-bound Keychain storage and user presence. Server/provider keys stay in server secure storage.
- Vault reads, secret enrollment, OTP retrieval, and biometric bypasses are not model tools.
- Device biometry/passcode authorization does not establish provider MFA. TOTP generates a code; the provider must issue and verify its challenge.
- Approval binds action ID, authenticated user/conversation, exact payload, relevant state/preferences version, expiry, and a one-time token. Changed terms require a new preview.
- Reserve an action before awaiting authentication or networking. Durable mutation adapters persist idempotency keys and reconcile uncertain results rather than retrying blindly.
- A model proposal never cancels, transfers, commits, or sends by itself. Label simulated actions.

## Integrated version 1

The iPhone entry point is `Examples/LanaDemoApp/LanaDemoApp.xcodeproj` (scheme `LanaDemoApp`). `FWMFeatureUI` composes `FinanceAI` and `FWMCore`; the root AI package remains independent of the UI. See [version 1](VERSION_1.md) for setup, merged branches, verification and remaining demo boundaries.

## Setup and verification

```bash
git clone https://github.com/tanish1608/speedrun-hacks26.git
cd speedrun-hacks26
git switch main
git pull --ff-only origin main
git switch -c codex/your-scope
swift test --package-path Packages/FWMCore
```

The AI module adds:

```bash
swift test
swift run ai-diagnostics
# Regenerate only after project.yml changes; generated project is checked in.
xcodegen generate --spec Examples/AIPlayground/project.yml
xcodebuild -project Examples/AIPlayground/AIPlayground.xcodeproj \
  -scheme AIPlayground -sdk iphonesimulator -configuration Debug \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Select an installed simulator or eligible physical phone in Xcode. Compilation without a simulator runtime does not verify launch, inference, speech, or device Keychain. Use your signing team for device runs; do not commit personal signing settings.

`FWMCore`: Swift tools 5.9+, iOS 17+/macOS 14+. Apple-model AI package: Swift tools 6.2+, iOS 26+/macOS 26+; current development toolchain is Xcode 27. Preserve concurrency checks. Shared engine tests need no model key, provider SDK, relay, or MLX.

### Fixtures

Ashwin owns updates. Do not regenerate during unrelated UI/AI work. For an intentional fixture change:

```bash
python3 fixtures/generate.py
git diff -- fixtures/
swift test --package-path Packages/FWMCore
```

Commit generator, generated JSON, and expected values together. Explain changed golden values; do not weaken assertions to hide failures.

September golden cents: income `480000`, expenses `315000`, savings `65000`, investments `40000`, retained cash `60000`, net worth `1155000`. Dinner: total `10920`, shares Ashwin `2860`, Tanish `3640`, Aryan `4420`, outstanding `8060`.

## Branch and merge workflow

- `main` is the integration branch. New lanes start from its current remote version.
- Tanish's existing branch: `codex/on-device-ai`. Suggested new branches: `codex/relay-adapters`, `codex/feature-ui-budget`. Continue actual existing branch names when applicable.
- Keep focused commits. Push your own lane and use PRs for feature integration. Preserve history with merge commits by default; do not rewrite another person's/shared branch.
- Direct `main` updates require explicit agreement for shared setup or an integration release; version 1 was explicitly requested by Tanish.
- Commit reviewed work before updating a branch; never discard uncommitted changes to clear a conflict.

```bash
git status --short
git fetch origin
git merge origin/main
swift test --package-path Packages/FWMCore
# Run AI/relay/UI checks appropriate to this change.
git diff --check
git push -u origin HEAD
```

The initial AI commits and first `main` commit were independently created before a shared base existed. The **one-time** AI integration needs an unrelated-history merge with explicit conflict resolution. Preserve both histories, `FWMCore`, and fixtures; combine `.gitignore` entries. New branches use the normal workflow above.

| Shared files | Coordination rule |
|---|---|
| `Contracts.swift`, `Dataset.swift` | Discuss additions with consumers; update tests and docs in the same PR |
| Package manifests | Coordinate dependencies/platform settings; avoid moving packages during a feature change |
| Xcode project / generator spec | Resolve spec/source changes first, then regenerate once |
| Canonical fixtures | Ashwin owns changes; preserve stable IDs and golden assertions |
| READMEs | Update affected sections instead of competing whole-file rewrites |
| `.gitignore` | Combine entries; never ignore source or canonical fixtures |

Do not resolve conflicts by choosing all of `--ours` or `--theirs`. Inspect both changes and verify affected consumers.

### PR handoff

- State user-visible behavior, affected lane, and reviewer/owner.
- Describe contract/data-mode changes and consumer migration.
- Identify mocked, unavailable, or unverified integrations.
- Report checks actually run; distinguish compilation, fallback, model inference, and provider sandbox tests.
- Give a reproducible integration example and required configuration.
- Shared-contract consumers review before merge. Unfinished provider calls do not return success.

## Current handoffs and open contracts

`main` version 1 includes all current lane branches. Feature UI adapters share the demo budget projection with chat; receipt review supplies trusted split context; optional relay pairing uses the current screen selection through a foreground worker. The fixture catalog remains a demo, and outbound split actions remain visibly simulated.

Tanish's AI module and standalone harness initially used pre-v2 DTOs and a cancellation scenario. Final integration consumes `FWMCore.ToolCall`, carries `Provenance` into `AgentResult`, binds relay identity to scope, and uses canonical fixtures. The cloud prototype stays unused; the integrated product is local-only.

Networking contracts are published in [relay/README.md](../relay/README.md). Before mutations: agree on action storage, payload/state versions, token issuance, idempotency, and provider challenge handling. Record concrete contracts here when their owners land them.

**Relay networking (proposed by Aryan, needs Tanish's review):** [relay/README.md](../relay/README.md#phone--relay-contract) covers pairing/auth, endpoints, ack/retry (90 s lease, idempotent results, `delivery_unknown` on send timeout), attachment proxying, the foreground nudge, and the approval signature for reminders.
