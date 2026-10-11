// Dev harness: plays both the sender and the paired phone against a running relay (RELAY_DEV=1).
// inbound text -> job -> phone claims it -> phone posts the result -> relay sends the reply
// then an approved reminder, the demo clock jumps 48h, and the reminder dispatches exactly once.
// Usage: RELAY=http://localhost:8787 PAIRING_CODE=123456 FROM=+15550001111 node scripts/fake-phone.ts
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { canonical } from '../src/canonical.ts';

const RELAY = process.env.RELAY || 'http://localhost:8787';
const FROM = process.env.FROM || '+15550001111';

async function call(method: string, path: string, body?: unknown, token?: string) {
  const res = await fetch(`${RELAY}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}
const step = (s: string, v: unknown) => console.log(`\n== ${s}\n${JSON.stringify(v, null, 2)}`);

const pair = await call('POST', '/v1/pair', { code: process.env.PAIRING_CODE || '123456' });
if (pair.status !== 200) throw new Error(`pairing failed: ${JSON.stringify(pair.body)}`);
const { device_token: token, approval_secret: secret } = pair.body;
step('paired', { paired_user_id: pair.body.paired_user_id });

step('inbound', (await call('POST', '/dev/inbound', { from: FROM, text: 'split dinner: Tanish had the pasta and half the app, Aryan the steak and half the app' })).body);

const job = await call('GET', '/v1/jobs/next?wait=5', undefined, token);
if (job.status !== 200) throw new Error('no job arrived');
step('phone claimed job', job.body);

// The real phone runs SplitEngine here. These are the SRS v2 golden numbers.
const result = {
  reply_text: 'Dinner $109.20. Tanish owes $36.40, Ashwin $28.60. Approve requests in FWM.',
  provenance: { result_id: 'split:rcpt_dinner_1011:v1', dataset_version: 'seed-v1', data_mode: 'fixture' },
};
const r1 = await call('POST', `/v1/jobs/${job.body.job_id}/result`, result, token);
const r2 = await call('POST', `/v1/jobs/${job.body.job_id}/result`, result, token);
step('result posted twice (one outbox row)', { first: r1.body.outbox.outbox_id, second: r2.body.outbox.outbox_id, same: r1.body.outbox.outbox_id === r2.body.outbox.outbox_id, delivery_state: r1.body.outbox.delivery_state });

// SPLIT-08: an approved reminder, bound to the exact payload and signed with the device's approval secret.
const actionId = `act_${randomUUID().slice(0, 8)}`;
const payload = { action_id: actionId, contact_id: 'c_tanish', to: FROM, body: 'Reminder: $36.40 for dinner on Oct 11.', due_at: new Date(Date.now() + 48 * 3600e3).toISOString() };
const payloadHash = createHash('sha256').update(canonical(payload)).digest('hex');
const nonce = randomUUID();
const expiresAt = new Date(Date.now() + 5 * 60e3).toISOString();
const mac = createHmac('sha256', secret).update(`${actionId}.${payloadHash}.${nonce}.${expiresAt}`).digest('hex');
const approval = { action_id: actionId, payload_hash: payloadHash, nonce, expires_at: expiresAt, mac };

const tampered = await call('POST', '/v1/reminders', { ...payload, body: 'Reminder: $99.00', approval }, token);
step('tampered payload rejected', { status: tampered.status, error: tampered.body.error?.user_message });
const rem = await call('POST', '/v1/reminders', { ...payload, approval }, token);
step('reminder scheduled', { status: rem.status, reminder_id: rem.body.reminder_id, state: rem.body.status });
const replay = await call('POST', '/v1/reminders', { ...payload, approval }, token);
step('replayed approval rejected', { status: replay.status, error: replay.body.error?.user_message });

step('advance demo clock 48h', (await call('POST', '/v1/clock/advance', { seconds: 48 * 3600 + 60 }, token)).body);
await new Promise((r) => setTimeout(r, 3500));
const ev = await call('GET', '/v1/evidence', undefined, token);
step('evidence', { reminders: ev.body.reminders.filter((x: any) => x.action_id === actionId), outbox: ev.body.outbox.slice(0, 3) });
