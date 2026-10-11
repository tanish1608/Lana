# FWMFeatureUI

Ashwin's Home, Money, Budget, Split and Accounts screens, connected to FinanceAI and FWMCore for Lana version 1. The centre orb opens free-form local chat with PDF input, saved history and reviewed voice. Shared money/split arithmetic remains in FWMCore; the demo catalog projection is shared between Budget, Home and chat through AIIntegration.swift.

Requires Swift 6.2+, iOS 26+/macOS 26+. Open `Examples/LanaDemoApp/LanaDemoApp.xcodeproj` for the integrated iPhone app; it bundles seed-v1.json. Host composition: `LanaRootView(store: try DemoStore(fixtureURL: bundledURL), unlocker: NativeVaultUnlocker())`.

```bash
swift test --package-path Packages/FWMFeatureUI
FWM_TEST_MODEL=1 swift test --package-path Packages/FWMFeatureUI --filter IntegrationTests/testActualIntegratedModelAnswersBudgetAndPDF
swift run --package-path Packages/FWMFeatureUI LanaMac
```

Real local operations: model inference, PDF extraction, receipt OCR with manual field reconciliation, speech transcription, device authentication, Keychain relay pairing and foreground job processing. Demo boundaries: fixture account connections, catalog-based budget suggestions, in-session budget adoption/receipt/request state, synthetic vault values, simulated Venmo handoff and split reminders. Provider MFA is not invented for synthetic keys. CSV import adapters and Sparta executor are merged libraries/tooling; their execution is not exposed as real financial actions in these screens.

See [version 1](../../docs/VERSION_1.md) for the complete handoff.
