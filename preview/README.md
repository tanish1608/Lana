# Lana web preview

An interactive phone-sized preview of the three demo journeys (Money, Budget, Split) plus the Vault screen.
It exists because the native app can't be built in every environment. **It is not the iOS app and proves nothing about native behavior** (Face ID, Keychain, TOTP, on-device model, OCR, speech, Messages delivery, Venmo).

## Run

From the repo root:

```bash
npx http-server -p 8080 .        # or: python3 -m http.server 8080
open http://localhost:8080/preview/web/
```

Use a phone-sized window, or open it on a phone on the same network. "Demo data" (top right) lists what is simulated and has **Reset demo**.

## Where the numbers come from

| Source | Used for |
|---|---|
| `fixtures/seed-v1.json` | Accounts, transactions, the Oct 11 receipt, contacts, split assignments |
| `preview/web/engine-port.js` | JS port of `MoneyEngine.moneyView` and `SplitEngine.prepareSplit/allocate`, because Swift can't run in a browser. FWMCore stays the source of truth. |
| `preview/web/engine-port.test.mjs` | Replays `EngineTests.swift` golden values against the port: `node --test preview/web/engine-port.test.mjs` |
| `preview/web/preview-data.js` | Labeled stand-ins the fixtures don't have yet: budget swap catalog and habits, the staged low-confidence OCR tip, the voice transcript, synthetic vault entries |

Nothing in the preview writes to storage. State lives in memory and resets on reload.

## Simulated, and labeled in the UI

- Messages delivery states and reminder sends (no Dial connection)
- Venmo handoff: details are copied; request and payment states are user-reported
- Keewano decision history (toggle in "Why these suggestions?")
- Face ID and authenticator steps in the vault; no code is verified
- Lana's chat replies are templated from the same engine results, not model output
- Swap prices are illustrative
