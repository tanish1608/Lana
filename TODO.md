# Lana — team task list

Version 1 is on `main` at `429351c`, tagged `v1.0.0`, and installed/launched on Tanish's iPhone. These are follow-up tasks, not claims that the integrations already work live. Owners below are suggested from the existing team lanes; confirm assignments by updating this file.

Read [version 1](docs/VERSION_1.md), [collaboration contracts](docs/README.md), and the relevant package before starting. New tasks start from current `origin/main` on focused branches. Preserve teammate history with merge commits, keep financial values in integer cents, and keep personal signing settings and secrets out of Git.

## Assignment board

Status: **Ready** can start now; **Blocked** needs the listed dependency; **Open** needs a product/integration decision. Change status to **In progress** when claimed, add the branch/PR, and check off the detailed task only when its acceptance criteria pass.

| ID | Priority | Task | Suggested owner | Status | Dependency | Branch / PR |
|---|---|---|---|---|---|---|
| QA-01 | P0 | Physical iPhone acceptance pass | Tanish + Ashwin | Ready | Connected, unlocked iPhone | — |
| RELAY-01 | P0 | Configure HTTPS relay and authorized senders | Aryan | Ready | Deployment access and local provider credentials | — |
| RELAY-02 | P0 | Verify paired iPhone messaging end to end | Tanish + Aryan | Blocked | RELAY-01 | — |
| MEM-01 | P1 | Connect Keewano preference memory to budget/chat | Aryan + Tanish | Ready | Configured query PAT; ingest key if new seeding is needed | — |
| STATE-01 | P1 | Persist budget, reviewed receipts and split state | Ashwin + Tanish | Open | Agree on persisted schema and reset behavior | — |
| BANK-01 | P1 | Add reviewed bank CSV account import | Aryan + Ashwin | Ready | Existing BankCSVProvider | — |
| UX-01 | P1 | Polish errors and input/review flows on device | Ashwin + Tanish | Ready | QA-01 findings refine scope | — |
| ACT-01 | P2 | Wire approved real split reminders | Aryan + Tanish + Ashwin | Open | RELAY-02; action storage and authorization design | — |
| SECURITY-01 | P1 | Assess relay SDK dependency audit findings | Aryan | Ready | Current relay lockfile | — |
| DEMO-01 | P0 | Prepare reproducible presentation and demo | Ashwin + team | Ready | Record actual live/unavailable integrations | — |

P0: next demo/integration priority. P1: reliability or next feature. P2: additional external-action scope. Work can proceed in parallel across owners where dependencies allow.

## Acceptance criteria

- [ ] **QA-01 — Physical iPhone acceptance pass.** Verify Home/Money/Budget/Accounts navigation, natural-language greeting and budget chat, History/New conversation, text and scanned PDFs, PDF removal, microphone transcript review/cancellation, receipt image review/assignment/reconciliation, Face ID or passcode, and background/foreground behavior. Relaunch and record which state survives. Confirm no stale financial evidence after changing a selection. Record device/OS, result and any bugs in the PR or a linked QA note. Installation/launch alone is not a completed acceptance pass.

- [ ] **RELAY-01 — Configure HTTPS relay and authorized senders.** Run the relay on a reachable HTTPS endpoint, configure its public URL and intended sender-to-user mapping, and document startup/pairing steps without secrets. Keep development inbound injection disabled on the shared deployment. Confirm health, durable state and restart behavior. Do not use the example `+14085550101` sender mapping as a real team configuration. Keys belong in the server's environment, not the phone bundle. Agree on the actual test participants before contacting them.

- [ ] **RELAY-02 — Verify paired iPhone messaging end to end.** Pair through Accounts with the correct fixture user, send an authorized test message, and verify Dial inbound → durable relay job → foreground iPhone CoreAgent/tools → result → reply. Capture event/job/provider IDs and source labels without raw secrets or unnecessary financial content. Exercise duplicate result delivery, app backgrounding, waiting jobs and authenticated reconnect. Report current provider delivery restrictions and whether the test is Dial-to-Dial or a personal phone. Do not claim continuous background inference.

- [ ] **MEM-01 — Connect Keewano preference memory.** Replace the integrated fixture-only preference-memory path with an injected relay/provider adapter. Keep authenticated user, eligible groups and preference versions scoped; preserve live/cached/unavailable provenance. Verify a rejected preference affects suggestions and the screen/chat agree. A Keewano PAT is for querying; ingestion/seeding requires its separate ingest key. Existing fixture behavior remains a labelled fallback, not a fabricated live result.

- [ ] **STATE-01 — Persist demo action and review state.** Agree on a versioned local schema for selected/adopted budget, reviewed receipt fields/assignments, reported split states and action history. Rehydrate safely after relaunch, bind records to the correct dataset/user, and provide an intentional demo reset. Invalidate stale proposals/evidence and avoid duplicate actions. State labelled paid remains user-reported unless a provider establishes settlement. Cover migration/reset and version mismatch with meaningful checks.

- [ ] **BANK-01 — Add reviewed bank CSV import.** Build a Files import/review UI over the existing BankCSVProvider, with account/user scope, useful validation errors and explicit dataset selection. Verify transfer/card repayment/refund/pending handling with existing engine expectations. Home, Money, Budget and chat must use the selected dataset and its provenance; exclude earlier dataset evidence from future context. Keep canonical fixtures available as a separate demo. This task does not establish live bank linking.

- [ ] **UX-01 — Polish device input/review flows.** Address observed keyboard, navigation, accessibility, progress/error and cancellation issues. Make model availability, local speech limits, PDF omissions and receipt corrections understandable. Preserve free-form chat and optional suggestions. All imported amounts and contact assignments remain explicitly reviewable; simulated actions remain labelled. Include screenshots or reproducible steps for the changed screens.

- [ ] **ACT-01 — Wire approved real split reminders.** Design durable exact action payload/version storage and the reviewed recipients/amounts/message preview. Native authentication and one-time approval must bind the current payload, user, expiry and state; validate again at the relay boundary. Changed terms require new review. Test duplicates, cancellation, changed state, expired/forged approvals and uncertain delivery. Keep real dispatch distinct from simulated controls. This task sends messages, not payments; real financial transfers and provider plan changes need their own design.

- [ ] **SECURITY-01 — Assess relay audit findings.** Inspect the current transitive Dial SDK findings, determine affected runtime paths, and make compatible upgrades or record concrete mitigations/upstream blockers. Run relay checks after dependency changes. Do not force a major migration merely to clear an audit count or silently claim unresolved findings are fixed.

- [ ] **DEMO-01 — Reproducible presentation.** Write a clean demo script for the three workflows, with fixture values, setup/reset instructions, an eligible Apple Intelligence device and an honest fallback if a provider is unavailable. Show natural chat, evidence, shared budget projection, reviewed receipt splitting, and saved PDF conversation. Only present live provider features after their acceptance tests pass. Capture measured workflow times separately from estimates and seeded history.

## Completed version 1 baseline

- [x] Merge AI, UI, data, engines/adapters, relay and Sparta branches while preserving history.
- [x] Connect native feature screens to free-form local AI chat, saved conversations and PDF input.
- [x] Share deterministic budget selection/projection between Budget, Home and chat.
- [x] Add local receipt image OCR and field/assignment review; exact split calculations.
- [x] Add local microphone transcription with transcript review and cleanup.
- [x] Connect device-owner authentication and optional protected relay pairing/foreground worker.
- [x] Pass relevant engine, AI/UI integration, fixture, web preview and relay tests, plus actual local model and local HTTP relay checks.
- [x] Publish `main` and `v1.0.0`; build, install and launch Lana on the physical iPhone.

## Verification and merge checklist

Run checks appropriate to the affected lane; see [version 1 verification](docs/VERSION_1.md#verification) for full commands. Ordinary Swift tests can skip actual model/live relay checks, so distinguish skipped tests, compilation, fallback behavior, actual inference and provider/device verification in the PR.

```bash
git fetch origin
git merge origin/main
swift test --package-path Packages/FWMCore
# Run affected AI/UI, relay, fixture or device checks.
git diff --check
git push -u origin HEAD
```

- Update the assignment board with the owner, status and branch/PR.
- Include changed behavior, actual checks, remaining limits and contract/provenance changes in the PR.
- Preserve personal Xcode signing edits and ignored local configuration when updating checkouts.
- Coordinate shared contract changes with their consumers; update docs and tests together.
- Keep fixture generators and expected values aligned; do not regenerate during unrelated work.
- Require explicit authorization for real external actions, and keep their review/idempotency safeguards intact.

## Current local configuration note

Tanish's Mac has `relay/.env` with Dial API key/number and Keewano query PAT configured locally. These are ignored and not shared through Git. The ingest key is not configured, sender mapping is still an example, and the base URL is localhost. RELAY-01 is still needed before a phone can use a deployed relay. The local `CLAUDE_HANDOFF.md` is also ignored; this task list and repository docs are the shared team handoff.
