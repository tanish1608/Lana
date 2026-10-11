# Lana 1.0 — integration handoff

## App and setup

Open `Examples/LanaDemoApp/LanaDemoApp.xcodeproj`. Select **LanaDemoApp**, an eligible physical iPhone, and your signing team; press Run. The checked-in project has no personal signing team. Minimum iOS/macOS 26, Swift 6.2; developed with Xcode 27. Apple Intelligence must be enabled with the local model downloaded for natural conversation. Unavailable models have a visible basic local fallback. No cloud LLM is used.

The app bundles `fixtures/seed-v1.json`, so it works on a phone without this checkout. `Examples/AIPlayground` remains a developer harness. Expanded synthetic data and PDFs live under `fixtures/world-v1`; they are intentionally separate scenarios and do not replace the canonical demo totals.

Regenerate only after changing the spec:

```bash
xcodegen generate --spec Examples/LanaDemoApp/project.yml
xcodebuild -project Examples/LanaDemoApp/LanaDemoApp.xcodeproj \
  -scheme LanaDemoApp -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/lana-build CODE_SIGNING_ALLOWED=NO build
```

For a signed phone build, use Xcode's Signing & Capabilities settings locally. Do not commit your team ID.

## Connected flows

- **Home / Money / Accounts:** FixtureProvider loads bundled data. MoneyEngine supplies cash flow, categories, balances and net worth. Home reflects the current selected budget projection and user-reported split states.
- **Lana chat:** ConversationalAssistant calls the on-device model directly, with scoped finance and PDF tools. Native tool selection can be skipped by the model, so the host also supplies current money, selected budget and reviewed split snapshots. Evidence is available below replies; it does not prove the model independently selected a tool.
- **Context / PDFs:** Local protected archives survive relaunch and can be reopened or separated with New conversation. The model receives bounded recent context and retrieved PDF passages. Paperclip imports text/scanned PDFs through PDFKit/Vision. Document figures remain separate from account balances. Removing an attachment removes it from future context. Originals and recordings are not saved in chat storage.
- **Budget:** The screen, Home card and FeatureTools share BudgetProjection, including selected options and the preference-history toggle. Adoption requires explicit review and device authentication in the iPhone host. A changed plan requires a fresh review. Adoption updates this demo session; it does not transfer money or switch services.
- **Split:** Files accepts an actual receipt image. Vision OCR and local structured extraction produce reviewable fields. The user verifies every item and amount, including subtotal/tax/tip/total reconciliation, then explicitly assigns contacts. SplitEngine calculates cents exactly; reviewed inputs are shared with chat. Imported receipt results are labelled cached local data. Original OCR text is available in the import sheet. A spoken note is transcribed locally and reviewed as text; it does not automatically invent item assignments.
- **Voice:** Tap microphone, record, tap stop, review the transcript, then send. Unsupported local speech asks for typed input. Recordings are deleted after transcription/error/cancellation; recording is cancelled when leaving the view or foreground. Maximum 60 seconds.
- **Accounts security:** NativeVaultUnlocker performs actual device-owner authentication and locks on navigation/background/timeout. Displayed vault entries are synthetic keys. There is no fake authenticator acceptance in the iPhone host; provider MFA is not configured for those synthetic credentials. KeychainVault and TOTP helpers remain available for a real provider challenge.
- **Relay:** Accounts → Configure messaging relay → HTTPS base URL + team pairing code. Pairing must match the fixture user and is saved in device-bound, user-presence-protected Keychain. Reconnect saved pairing requests authentication. RelayWorker runs only while the app is active, with the current scope and selected tools. Background jobs remain on the relay; it supplies the foreground nudge. Relay task routing is scoped and deterministic/model-classified, separate from free-form in-app chat. Relay attachments require review in the app; they are not automatically imported into chat.

Dataset/selection revisions exclude old financial evidence from subsequent context. An answer already being generated retains its original snapshot and warns when the selection changes. No model receives vault secrets or generates approval tokens.

## Remaining demo boundaries

Account linking still displays an explicit unavailable/demo notice. The fixture provider is wired; BankCSVProvider is available to integrate when an account-import flow is designed. The budget catalog is the reviewed demo catalog, not live product pricing. Provider calls, Keewano memory and Dial delivery require team server configuration; no keys are embedded in the app.

Venmo handoff and split-reminder controls are explicitly simulated. User-reported paid/requested states do not establish bank settlement. No payment, real phone-plan switch, automatic reminder or financial mutation is performed by these screens. The relay's approved-reminder API and Sparta's approval/idempotency executor are merged and tested separately, not represented as integrated live financial actions.

Chats and PDF text persist; budget adoption, reviewed receipts, request states and the local action log currently last for the app session. Restarting restores canonical fixture screens. Previously saved financial answers retain their evidence labels and are excluded from context when the dataset revision differs.

Relay dependency installation reports transitive npm audit findings in the Dial SDK dependency tree. Nonbreaking `npm audit fix` did not resolve them. The team should assess these before operating a production relay; no SDK downgrade or unrelated forced dependency migration was applied.

## Verification

```bash
swift test
swift test --package-path Packages/FWMCore
swift test --package-path Packages/FWMFeatureUI
FWM_TEST_MODEL=1 swift test --package-path Packages/FWMFeatureUI \
  --filter IntegrationTests/testActualIntegratedModelAnswersBudgetAndPDF
python3 -m tools.synthetic_data.validate
node --test preview/web/engine-port.test.mjs
(cd relay && npm ci && npm test)
```

Integration checks cover selected budget arithmetic, user/ownership scope, stale preference rejection, exact receipt amounts and reconciliation, trusted reviewed receipt IDs, and exclusion of earlier financial evidence. Actual model evaluation checks a greeting, the budget's $150 projection and a PDF's $220 statement balance independently of the fixture's $650 savings transfer. The Swift client also passed a live HTTP loop against a local Dial-disabled relay: pairing, job retrieval/result deduplication, a signed test reminder and rejection of a forged approval. Native Mac UI verification exercised a natural-language budget question through Ashwin's chat panel and displayed the $150 answer. A signed physical-iPhone build compiles; phone launch/voice/Face ID on this integrated version need an available device. Earlier AI harness device verification does not establish these new screen flows.

September remains income $4,800, expenses $3,150, savings $650, investments $400, retained $600, net worth $11,550. Canonical dinner remains $109.20, with $28.60 / $36.40 / $44.20 shares and $80.60 outstanding before user reports.

## History and ownership

Version 1 preserves the full histories of `ashwin/ui-demo`, `ashwin/demo-data`, `codex/on-device-ai`, `codex/relay-worker` (including relay-adapters), `codex/aggregator-adapters` and `codex/sparta-worlds`. Integration work is on `codex/version-1`, published to `main` at Tanish's explicit request. Each owner's lane remains intact. Continue new work from current main and use focused commits/merge commits.

Tanish owns local inference, context, OCR/voice, security and composition; Ashwin owns feature UI, fixture/catalog behavior and presentation; Aryan owns engines, normalized providers, relay and sponsor integration. Shared changes update the affected consumers and checks together. Keep personal signing changes, build artifacts, pairing credentials and user documents out of Git.
