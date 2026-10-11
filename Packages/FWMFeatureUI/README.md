# FWMFeatureUI

Ashwin's SwiftUI feature screens: Home, Money (pushed from Home), Budget, Split and Accounts (connected accounts plus the access keys behind Face ID), with an in-app Lana chat, composed in `LanaRootView`. Screens read `FWMCore` results (`MoneyEngine`, `SplitEngine`) from a `DemoStore` loaded with `fixtures/seed-v1.json`. No engines, model, relay or provider code lives here.

```bash
swift test --package-path Packages/FWMFeatureUI          # fixture wiring + budget stand-in checks
swift run  --package-path Packages/FWMFeatureUI LanaMac  # quick look in a Mac window
open Packages/FWMFeatureUI/Package.swift                 # Xcode: LanaRootView.swift has a #Preview
```

Host integration: `LanaRootView(store: try DemoStore(fixtureURL: bundledSeedURL), unlocker: <native VaultUnlocking>)`.

Stand-ins, all labeled in the UI:
- `PreviewBudgetPlan` (BudgetScreen.swift) until the swap catalog and budget engine land.
- `SimulatedVaultUnlocker` until the host passes an implementation backed by Tanish's SecureVault / DeviceOwnerAuthenticator / TOTP.
- Sample transcript and a staged low-confidence tip read (SplitScreen.swift).
- Messages delivery, reminder sends and Venmo handoff are recorded as states only.
