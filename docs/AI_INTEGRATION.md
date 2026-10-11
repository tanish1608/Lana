# AI module integration

Implemented on `codex/on-device-ai`. This is a concrete handoff for the shared [collaboration guide](README.md). The integrated path uses `FWMCore` contracts and local inference. It contains no cloud model calls.

## Package and app

The root `FinanceAI` Swift package depends on `Packages/FWMCore`. Import both products in the host app. `Examples/AIPlayground/AIPlayground.xcodeproj` is the checked-in AI harness; its generator spec bundles the canonical `fixtures/seed-v1.json`. Its chat calls the existing money and split engines rather than implementing a second set of calculations.

The final three feature UIs remain Ashwin's lane. Budget/swaps, provider adapters, and relay networking are dependency-injection points; missing adapters return `PROVIDER_UNAVAILABLE` instead of fabricated success. The original pre-v2 `FinanceAgent`/`OnDeviceRouter` are compatibility prototypes. Do not use their financial DTOs at a shared app/relay boundary, and do not enable the unused prototype `CloudRelayRouter` in the product.

## App/relay entry point

### Conversational iPhone chat

The harness and integrated Lana chat use `ConversationalAssistant`, a free-form Foundation Models session with native `finance` and `readPDF` tools. Greetings and general questions reach the model directly; the old topic router and its keyword preflight are not the conversational app path. The model decides when to read financial data or discuss a document. Available financial tools use the same injected `CoreToolExecuting` adapters and scope validation. Pending mutations remain host review controls; vault secrets are not conversation context.

Every turn supplies a deterministic money snapshot for the current period, plus selected budget and reviewed split snapshots when the host provides them. This grounds answers when the model skips an optional native tool call. The snapshot and any additional engine results appear below replies; their presence does not imply the model independently chose a tool. Earlier smoke runs exposed inconsistent optional tool selection, so tool selection is not claimed as universally reliable.

`ConversationStore` saves each `ConversationArchive` (messages, engine evidence, and extracted PDF text) in app-private Application Support storage. Files are excluded from backup and use complete file protection on iOS. Chats survive relaunch, can be reopened from History, and stay separate when creating a new chat. Originals and recordings are not copied into chat storage. All history is retained locally; the model receives up to eight recent messages, recent evidence for the current dataset, and relevant PDF excerpts. This is bounded context, not unlimited model memory. No cloud sync is implemented.

The paperclip imports a PDF through Files. `PDFTextImporter` uses PDFKit for text and local Vision OCR for scanned pages. The importer supports up to 50 MB, 100 pages, and 300,000 extracted characters; omissions and OCR are labelled. `readPDF` can retrieve excerpts from later pages and by page number. Document text is source material, not authority to execute instructions. Questions about a PDF use its figures separately from the demo account snapshot; importing a document does not update the account dataset. Summaries use retrieved passages and may not cover every page. Removing an attachment removes its extracted text from subsequent model context; earlier conversation replies remain in the history.

Financial source results and provenance stay visible below model replies. A generated explanation is not an accounting engine result. If inference is unavailable, an offline greeting and supported deterministic finance reads remain available, with the fallback source labelled.

### Paired relay jobs

1. Build `CoreScope` from authenticated pairing and an owned dataset. Supply user/conversation IDs, default period, dataset/preferences versions, owned IDs, and optional active budget.
2. Build `CoreRoutingContext`. An attachment ID comes from the local attachment store. A `ReviewedSplit` comes from the receipt review UI, not a model.
3. Inject `CoreToolExecuting` into `CoreAgent`. `CoreDatasetTools` implements the already-landed money and split engines. A composite adapter can delegate the other tools to their owning lanes.
4. Call `process(_:jobID:)` with the shared `MessageEnvelope`. Use `response.result` as `AgentResult` for the relay, and the same provenance/card ID for views.

```swift
import FinanceAI
import FWMCore

let scope = CoreScope(
    userID: dataset.user.userId,
    conversationID: authenticatedConversationID,
    period: "2026-09",
    datasetVersion: dataset.datasetVersion,
    preferencesVersion: dataset.user.preferencesVersion,
    accountIDs: Set(dataset.accounts.map(\.accountId))
)
let agent = CoreAgent(
    context: CoreRoutingContext(scope: scope),
    tools: CoreDatasetTools(dataset: dataset)
)
let response = try await agent.process(authenticatedEnvelope, jobID: relayJobID)
let wireData = try FWMJSON.encoder.encode(response.result)
```

The agent rejects another paired user/conversation, validates tool scope, checks result dataset version/currency, and requires provenance for financial tools. Same-content duplicate event IDs share work and receive the appropriate caller job ID; a conflicting replay is rejected. Session-local dedupe is bounded. Aryan's relay still needs durable event/job dedupe and acknowledgements. Explicit cancellation uses `agent.cancel(eventID:)`; a caller disappearing does not silently cancel other waiters for the same event.

`CoreRouter` classifies tool families locally with Foundation Models' specialized `contentTagging` use case and supplies object IDs from trusted context. Dollar-to-cent parsing is deterministic and bounded; named or relative months needing interpretation request YYYY-MM clarification. Known phrases use fast offline rules; unfamiliar language uses the model. The result source identifies which route ran. `CoreRouter(preferRules: false)` is for model evaluation, not a different authorization policy.

## Budget/swaps and mutations

Ashwin's composite `CoreToolExecuting.query` handles `propose_budget` / `suggest_swaps`; Aryan's handles `get_swap_memory` and provider reads. These calls remain read-only or proposal creation. Do not implement mutations inside `query`.

`CoreApprovalGate` is the host-only mutation boundary:

1. The owning adapter stores the exact action proposal/payload and returns its action ID and version.
2. The host stages a `CoreActionProposal` with kind `.budgetPlan` or `.reimbursementRequests`, payload version, and a preview summary of terms/recipients/amounts.
3. An explicit review control invokes `approve(actionID:humanResponse: "YES")`. Device owner authentication is required by default.
4. The gate checks expiry and `CoreActionCommitting.currentVersion`, generates a random one-time capability, and passes the canonical `commitBudgetPlan` / `dispatchRequests` tool to `commit(_:authorization:)`.

The adapter must scope the stored action, validate authorization/expiry and version again **atomically**, persist idempotency by action ID, and reconcile uncertain provider outcomes. The gate reserves before awaiting auth/networking to prevent concurrent duplicate commits. It never treats a model-supplied token or a bare YES from another conversation as approval. Failures require a refreshed proposal, not automatic mutation retry. Gate state is in-memory; persistent action/audit storage remains an adapter responsibility.

## Receipt and voice

```swift
let document = try await ReceiptOCR().recognize(imageData: imageBytes)
let draft = try await ReceiptDraftBuilder().build(from: document)
// Show original OCR, confidence, proposed item fields, and totals for user review.
// Import only reviewed/corrected fields into FWMCore.Receipt, then reconcile/split.
```

Vision reads image bytes locally. Foundation Models extracts exact source strings into a review-required draft; unsupported generated fields fall back to raw OCR. The draft is not an accounting record, and field presence is not proof of correct line association. If the local model is unavailable or the receipt is too long, raw OCR remains available. No draft is imported automatically.

For push-to-talk, use `VoiceRecorder.start()` / `stop()` and `OnDeviceSpeechTranscriber.transcribe(fileURL:)`. The transcriber verifies local recognition support, requires on-device processing, handles cancellation, and times out. The host deletes the recorded file in a `defer` block, including failures, and presents editable text before sending. The harness Voice tab demonstrates these calls. Add microphone and speech usage descriptions to the host Info.plist.

## Vault and MFA

`KeychainVault` implements `SecretStoring`; the key includes authenticated user ID and service name. Items are passcode-required, device-only, nonsynchronizing, and user-presence protected. No insecure storage fallback exists. Never put vault reads or enrollment in a model tool registry.

`DeviceOwnerAuthenticator` uses device owner authentication (biometry or passcode). Host Info.plist needs `NSFaceIDUsageDescription`. `VaultTOTPService` enrolls an explicitly provided Base32 secret and generates RFC 6238 codes after protected secret access. It does not verify a provider's challenge or establish server-side MFA. The harness stores only a public RFC test secret; personal credentials do not belong in fixtures.

## Checks and actual verification

```bash
swift test
swift test --package-path Packages/FWMCore
swift run ai-diagnostics
swift run ai-diagnostics --model
swift run ai-diagnostics --chat
FWM_RUN_NATIVE_OCR=1 swift test --filter visionReadsReceiptImageLocally
```

`--model` evaluates actual model classification for supported samples; blocked side effects still go through deterministic preflight. Inspect source labels. A fallback result is not evidence of model quality. On this Mac, the canonical router matched all six supported prompts using local inference and blocked two additional prompts using preflight (8/8 total). Observed model calls took approximately 1.5–9.4 seconds. This is a small smoke evaluation, not an accuracy or iPhone latency benchmark. The initial pre-v2 general-model run matched 6/8; the canonical classifier uses a different use case and explicit topic instructions.

`--chat` separately evaluates free-form greetings, a remembered name, an engine-grounded financial reply, answering from attached document text, and keeping a PDF's financial figures separate from the account fixture. It requires actual on-device generation for all five checks. Unit tests also exercise persisted chat restoration/owner isolation, bounded context, later-page retrieval, and extraction from a generated PDF.

The package tests cover canonical money/split values, scope checks, invalid amounts/months, replay dedupe/cancellation, stale approvals, concurrent confirmations, TOTP RFC vectors, and OCR field validation. The opt-in macOS test runs actual Vision OCR on a generated receipt image; it can take time to initialize native services and is skipped by default. The harness builds for the iOS simulator SDK. This development machine currently has no available simulator runtime, so launch, phone inference, speech permission/audio capture, Face ID, and device Keychain require an eligible physical iPhone or an installed runtime. Compile success does not mark those checks complete.

No relay endpoints, signing team, provider tokens, live merchant writes, or complete budget/swap engine are invented by this module. Connect the owning adapters through the protocols above, keeping the shared contracts and test values intact.

## Version 1 composition

`Packages/FWMFeatureUI/AIIntegration.swift` connects the screen selections to scoped tools. `LanaChatController` reuses the archive/PDF infrastructure; `ChatPanel` renders actual conversational replies. Budget edits and reviewed receipt changes invalidate old engine evidence. Host prefetches ground answers when optional tool selection is skipped. `RelaySettings` pairs through `RelayClient` and reads current UI state for foreground jobs. See [VERSION_1.md](VERSION_1.md) for the app entry point and explicit remaining demo boundaries.
