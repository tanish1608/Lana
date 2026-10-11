# sparta/

Lana's money actions tested in a [Sparta Worlds](https://www.usesparta.co) sandbox (`sparta_worlds@0.9.0-beta.3`, Customer Desk template with its Stripe twin). Aryan's lane.

## The workflow under test

Lana proposes a swap on the phone: Ashwin's carrier plan goes from Unlimited Plus ($65/mo) to Essentials ($45/mo), a $20/mo saving (SRS budget swap). Ashwin approves it on the confirm screen, the phone signs the approval, and the executor applies it to billing. The executor is plain code. No model runs at this step.

`projects/lana-phone-plan/` is our own project: seed (Ashwin's phone plan, his StreamBox subscription, his roommate's phone line, ticket 1), four missions, and declarative checks. `make-missions.mjs` generates the missions with approvals signed the same way the relay checks them.

| Mission | What arrives | Expected |
|---|---|---|
| `swap-approved` | the approved switch | price changes once, ticket 1 solved with one reply, nothing else touched |
| `swap-not-approved` | the switch with no approval | no billing write at all, ticket 1 pending with one reply |
| `swap-tampered` | approved for Ashwin's line, delivered pointing at the roommate's line | no billing write, ticket 1 pending |
| `swap-redelivered` | the same approved switch twice, as after a relay timeout | applied once, one reply |

Every mission also checks that the roommate's line and the StreamBox subscription are unchanged, and that nothing refunds, cancels or creates proration lines.

## Failure, fix, rerun

`executor-v1.mjs` is the first version, kept as the baseline. `executor.mjs` is the fix. Same seed, same checks.

| Run | v1 | v2 |
|---|---|---|
| normal, 4 missions | 1 of 4 pass | 4 of 4 pass |
| `--scenario interruption` (first connector call returns 500), 4 missions | 0 of 4 pass | 4 of 4 pass |

What v1 got wrong, and the change in v2:

1. **It applied an unapproved switch** and **wrote to the roommate's line** when the action changed after approval. v2 verifies the approval against the exact payload (sha256 of canonical JSON, HMAC with the device secret, expiry) before any billing call. In the sandbox, `sub_lana_phone` and `sub_roommate_phone` now see zero write requests on those missions.
2. **It posted two confirmations on redelivery.** v2 stamps `metadata.lana_action_id` on the subscription and reads it before writing, so a second delivery is a no-op.
3. **It crashed on the first 500.** v2 retries up to 3 times with a stable `Idempotency-Key` on the billing write, and reads ticket comments before retrying a reply so a retry can't double-post.

Evidence for all four runs is in `evidence/` (`lana-v1-normal.json`, `lana-v1-interruption.json`, `lana-v2-normal.json`, `lana-v2-interruption.json`).

## Reproduce

```bash
cd sparta
npm install --ignore-scripts
cd projects/lana-phone-plan && node make-missions.mjs && cd ../..
npx --no-install worlds starters run --project ./projects/lana-phone-plan --all -- node executor-v1.mjs
npx --no-install worlds starters run --project ./projects/lana-phone-plan --all -- node executor.mjs
npx --no-install worlds starters run --project ./projects/lana-phone-plan --all --scenario interruption -- node executor.mjs
npx --no-install worlds starters open --project ./projects/lana-phone-plan   # browser view of the world and grades
```

Node 24+. `sparta-demo-device-secret` is a test-only secret shared by `make-missions.mjs` and `executor.mjs`.

## Limits

- The interruption scenario fails a request before the handler runs. It does not test a write that succeeded but timed out. The relay handles that case separately by marking the send `delivery_unknown` and not retrying it.
- Approvals in the missions expire on 2026-12-31 so the fixed mission files stay valid.
