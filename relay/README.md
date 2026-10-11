# relay/

Aryan's lane. A small Node service between messaging and the phone:

- Dial inbound (text, receipt photos, voice notes) becomes a durable job for the paired phone.
- The phone runs the model and engines, then posts an `AgentResult`. The relay sends the reply on the same channel.
- Approved reminders (SPLIT-08) dispatch on a demo clock.
- Keewano swap memory (BUD-04) for `get_swap_memory`.

The relay **never calls an LLM** and never sees balances or transactions. It stores message routing, job state, the outbox and reminders in `data/relay.db` (SQLite). Restarts are safe at any point.

## Run

```bash
cd relay
npm install
cp .env.example .env      # fill in DIAL_API_KEY, PAIRED_PHONES
npm start                 # prints the pairing code; DIAL_DEBUG=1 logs raw stream events
npm test                  # end-to-end checks against a real server, Dial off
RELAY_DEV=1 npm start     # then, in another shell:
npm run fake-phone        # plays sender + phone: message -> job -> reply -> approved reminder -> clock +48h
npm run seed:keewano      # needs KEEWANO_API_KEY; backfills swap history (instant coffee rejected 3x)
```

Node 23.6+ (runs TypeScript directly and uses `node:sqlite` without flags). Built on Node 25.

## Phone ↔ relay contract

The app should use `FWMCore.RelayClient` (`Packages/FWMCore/Sources/FWMCore/RelayClient.swift`) instead of hand-rolling these calls. `Approval.sign` produces the exact bytes the relay checks, and `RelayClientTests.testApprovalMatchesRelayBytes` pins a vector from `src/canonical.ts`.

```swift
let pairing = try await RelayClient.pair(baseURL: relayURL, code: "123456")   // once; Keychain both secrets
let relay = RelayClient(baseURL: relayURL, deviceToken: pairing.deviceToken)
while appIsForeground {
    guard let job = try await relay.nextJob() else { continue }
    // route job.envelope through the on-device model + engines, then:
    try await relay.postResult(AgentResult(jobId: job.jobId, replyText: reply, provenance: result.provenance))
}
```

Every `/v1/*` call except `/v1/pair` sends `Authorization: Bearer <device_token>`. Errors use the FWMCore shape: `{"error": {"code": "AUTH_REQUIRED", "retryable": false, "user_message": "..."}}`.

| Call | Body / query | Returns |
|---|---|---|
| `POST /v1/pair` | `{"code": "123456", "paired_user_id"?: "user_ashwin"}` | `{device_token, approval_secret, paired_user_id}`. Store both secrets in the Keychain. |
| `GET /v1/jobs/next?wait=25` | long poll, max 30 s | `200 {job_id, envelope}` (`MessageEnvelope`, snake_case) or `204` |
| `GET /v1/attachments/:attachment_id` | | the bytes, with Content-Type. Only for this device's user. |
| `POST /v1/jobs/:job_id/result` | `AgentResult` fields: `reply_text`, `card_id`?, `proposed_action_id`?, `provenance`?, plus `card`?: `{base64, content_type}` for an image to attach | `{job_id, outbox}` |
| `POST /v1/reminders` | `{action_id, split_id?, contact_id, to, body, due_at, approval}` | `201` reminder, or the existing one for that `action_id` |
| `POST /v1/reminders/:id/status` | `{"status": "paid" \| "disputed" \| "cancelled"}` | reminder (only a `scheduled` one changes) |
| `POST /v1/clock/advance` | `{"seconds": 172800}` | `{demo_now}` |
| `GET /v1/swap-memory?user_id=user_ashwin&groups=a,b` | | `{blocked_groups, evidence_ids, as_of, data_mode: live\|cached, query}` |
| `GET /v1/evidence` | | recent jobs, outbox rows with Dial message IDs, reminders (integration evidence, T09) |
| `GET /health` | no auth | `{ok, dial, from, demo_now}` |

**Identity.** The relay maps the sender's number to `paired_user_id` through `PAIRED_PHONES`. Messages from other numbers are dropped. Nothing in the message text can change the user.

**Acknowledgement and retry.** An inbound event is deduplicated by event ID and Dial message ID, then stored as a job before anything else happens. Claiming a job leases it for 90 s. If no result arrives, the next poll gets it again with `retry_count + 1`. A result is idempotent per job: posting twice sends once. A send that times out is marked `delivery_unknown` and is not retried blindly. Only `failed` sends retry.

**Foreground.** A device that polled in the last 20 s counts as open. If no device is open 6 s after a message arrives, the sender gets one nudge: `Got it. Open FWM to finish: fwm://job/<job_id>`. The job waits in the queue until the app opens.

**Attachments.** The relay keeps only Dial's media URL and proxies it to the paired device. Dial media URLs are stable and do not expire (Dial docs, confirmed by the Dial team on Oct 11), so the relay does not cache bytes.

**Approvals (ACT-02).** An approval binds the exact payload, a nonce and an expiry, and the device signs it after MFA:

```
payload_hash = sha256_hex(canonical_json(payload))   // keys sorted, no whitespace
mac = hmac_sha256_hex(approval_secret, "<action_id>.<payload_hash>.<nonce>.<expires_at>")
approval = {action_id, payload_hash, nonce, expires_at, mac}
```

For reminders, `payload = {action_id, contact_id, to, body, due_at}`. A changed payload, an expired or reused nonce, or a bad signature returns `403 AUTH_REQUIRED` and nothing is scheduled. `src/canonical.ts` is the reference implementation.

## Status

| Piece | State |
|---|---|
| Job queue, pairing, idempotent replies, approvals, reminders, demo clock | `npm test` passes (5 end-to-end tests) |
| Swift client | `swift test` passes; `testLiveRelayLoop` ran against a local relay (pair, job, result, signed reminder, forged approval rejected) |
| Dial send/receive | Verified live at 1:19 PM: Dial's Test Inbound SMS reached the relay over the event stream, became a job for user_ashwin, and the relay sent the "Open FWM" nudge back through Dial (provider message ID recorded in `/v1/evidence`). Our number is SMS/voice. Inbound SMS from any phone works. Outbound SMS to US numbers is blocked until 10DLC registration ($25, 3 to 5 days), and iMessage costs $250 up front, so the demo shows replies in the app. |
| Dial webhook | Signature check written. Not exercised; the event stream is the primary path. |
| Keewano swap memory | Events registered and history ingested (`npm run seed:keewano`). Query verification pending ingest processing. |
| Sparta Worlds runner | Not started |
