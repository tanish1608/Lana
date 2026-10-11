// End-to-end relay checks against a real server process with Dial off (sends land in the outbox as failed).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { canonical } from '../src/canonical.ts';

const PORT = 18000 + Math.floor(Math.random() * 1000);
const BASE = `http://localhost:${PORT}`;
const PHONE = '+15550001111';
let server: ChildProcess;
let token = '';
let secret = '';

async function call(method: string, path: string, body?: unknown, auth = true) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(auth && token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

function approve(actionId: string, payload: unknown, expiresInMs = 60_000) {
  const payloadHash = createHash('sha256').update(canonical(payload)).digest('hex');
  const nonce = randomUUID();
  const expiresAt = new Date(Date.now() + expiresInMs).toISOString();
  const mac = createHmac('sha256', secret).update(`${actionId}.${payloadHash}.${nonce}.${expiresAt}`).digest('hex');
  return { action_id: actionId, payload_hash: payloadHash, nonce, expires_at: expiresAt, mac };
}

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), 'fwm-relay-'));
  server = spawn(process.execPath, ['src/server.ts'], {
    env: { ...process.env, DIAL_API_KEY: '', DIAL_SELF_HOSTED_SECRET: '', KEEWANO_API_KEY: '', KEEWANO_PAT: '', MANUAL_ESTIMATES_SECONDS: 'month_review=900,bill_split=999', PORT: String(PORT), RELAY_DEV: '1', RELAY_DB: join(dir, 'relay.db'), PAIRING_CODE: '424242', PAIRED_PHONES: `${PHONE}=user_ashwin` },
    stdio: 'ignore',
  });
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(`${BASE}/health`)).ok) break; } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  const pair = await call('POST', '/v1/pair', { code: '424242' }, false);
  assert.equal(pair.status, 200);
  ({ device_token: token, approval_secret: secret } = pair.body);
});

after(() => server.kill());

test('wrong pairing code and missing token are rejected', async () => {
  assert.equal((await call('POST', '/v1/pair', { code: '000000' }, false)).status, 401);
  assert.equal((await call('GET', '/v1/jobs/next?wait=0', undefined, false)).status, 401);
});

test('inbound message becomes one job; a redelivered event does not', async () => {
  await call('POST', '/dev/inbound', { event_id: 'evt_dup', from: PHONE, text: 'how did I do in September?' }, false);
  await call('POST', '/dev/inbound', { event_id: 'evt_dup', from: PHONE, text: 'how did I do in September?' }, false);
  const job = await call('GET', '/v1/jobs/next?wait=1');
  assert.equal(job.status, 200);
  assert.equal(job.body.envelope.paired_user_id, 'user_ashwin');
  assert.equal(job.body.envelope.event_id, 'evt_dup');
  assert.equal((await call('GET', '/v1/jobs/next?wait=1')).status, 204);

  const result = { reply_text: 'September: $4,800 in, $3,150 spent.', provenance: { result_id: 'mv:seed-v1:2026-09:all' } };
  const a = await call('POST', `/v1/jobs/${job.body.job_id}/result`, result);
  const b = await call('POST', `/v1/jobs/${job.body.job_id}/result`, result);
  assert.equal(a.body.outbox.outbox_id, b.body.outbox.outbox_id);
});

test('unpaired senders never create jobs', async () => {
  await call('POST', '/dev/inbound', { from: '+15559999999', text: 'hi' }, false);
  assert.equal((await call('GET', '/v1/jobs/next?wait=1')).status, 204);
});

test('reminder needs an approval bound to the exact payload, used once, and fires once on the demo clock', async () => {
  const actionId = `act_${randomUUID().slice(0, 8)}`;
  const payload = { action_id: actionId, contact_id: 'c_tanish', to: PHONE, body: 'Reminder: $36.40 for dinner.', due_at: new Date(Date.now() + 48 * 3600e3).toISOString() };
  const approval = approve(actionId, payload);

  assert.equal((await call('POST', '/v1/reminders', { ...payload, body: 'Reminder: $99.00', approval })).status, 403);
  assert.equal((await call('POST', '/v1/reminders', { ...payload, approval: approve(actionId, payload, -1000) })).status, 403);
  assert.equal((await call('POST', '/v1/reminders', { ...payload, approval: { ...approval, mac: '00'.repeat(32) } })).status, 403);
  const ok = await call('POST', '/v1/reminders', { ...payload, approval });
  assert.equal(ok.status, 201);
  assert.equal((await call('POST', '/v1/reminders', { ...payload, approval })).status, 403);

  await call('POST', '/v1/clock/advance', { seconds: 48 * 3600 + 60 });
  await new Promise((r) => setTimeout(r, 2500));
  const ev = await call('GET', '/v1/evidence');
  const rows = ev.body.reminders.filter((r: any) => r.action_id === actionId);
  assert.equal(rows.length, 1);
  assert.notEqual(rows[0].status, 'scheduled');
  assert.equal(ev.body.outbox.filter((o: any) => o.idempotency_key === `reminder:${rows[0].reminder_id}`).length, 1);
});

test('a paid request cancels its reminder before it fires', async () => {
  const actionId = `act_${randomUUID().slice(0, 8)}`;
  const payload = { action_id: actionId, contact_id: 'c_aryan', to: PHONE, body: 'Reminder: $44.20 for dinner.', due_at: new Date(Date.now() + 365 * 86400e3).toISOString() };
  const rem = await call('POST', '/v1/reminders', { ...payload, approval: approve(actionId, payload) });
  const paid = await call('POST', `/v1/reminders/${rem.body.reminder_id}/status`, { status: 'paid' });
  assert.equal(paid.body.status, 'paid');
});

test('time receipt averages measured runs per chore and reports minutes saved', async () => {
  assert.equal((await call('POST', '/v1/timings', { workflow: 'bill_split', mode: 'manual', seconds: 0 })).status, 400);
  for (const [mode, seconds] of [['manual', 560], ['manual', 640], ['lana', 40]] as const)
    assert.equal((await call('POST', '/v1/timings', { workflow: 'bill_split', mode, seconds })).status, 201);
  const r = await call('GET', '/v1/time-receipt');
  const split = r.body.rows.find((x: any) => x.workflow === 'bill_split');
  assert.deepEqual([split.manual_seconds, split.lana_seconds, split.saved_seconds, split.manual_runs], [600, 40, 560, 2]);
  assert.equal(r.body.data_mode, 'local');
  assert.equal(split.manual_source, 'measured'); // a measured run beats the bill_split estimate
  const review = r.body.rows.find((x: any) => x.workflow === 'month_review');
  assert.deepEqual([review.manual_seconds, review.manual_source, review.saved_seconds], [900, 'estimate', null]);
  assert.equal(r.body.rows.find((x: any) => x.workflow === 'budget_swaps').manual_source, null);
});

test('browser clients get CORS headers and the stopwatch page loads', async () => {
  const pre = await fetch(`${BASE}/v1/time-receipt`, { method: 'OPTIONS', headers: { Origin: 'http://localhost:5173', 'Access-Control-Request-Headers': 'authorization' } });
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get('access-control-allow-origin'), '*');
  assert.match(pre.headers.get('access-control-allow-headers') || '', /Authorization/);
  const page = await fetch(`${BASE}/timer`);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /Lana stopwatch/);
});

/** Plays Dial's side of a Self-Hosted call: frames in, the agent's response frames out. */
async function dialCall(callId: string, from: string) {
  const ws = new WebSocket(`ws://localhost:${PORT}/dial/voice/${callId}`);
  const frames: any[] = [];
  ws.onmessage = (e) => frames.push(JSON.parse(String(e.data)));
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  ws.send(JSON.stringify({ type: 'call_connected', call_id: callId, direction: 'inbound', from, to: '+13144649040', instruction: null, language: 'en-US' }));
  const until = async (pred: () => boolean) => { for (let i = 0; i < 100 && !pred(); i++) await new Promise((r) => setTimeout(r, 50)); };
  return { ws, frames, until };
}

test('a call turn is answered by the paired phone and spoken back, never sent as SMS', async () => {
  const { ws, frames, until } = await dialCall('call_test1', PHONE);
  ws.send(JSON.stringify({ type: 'response_required', response_id: 0, transcript: [] }));
  await until(() => frames.length >= 1);
  assert.match(frames[0].content, /this is Lana/);

  ws.send(JSON.stringify({ type: 'ping_pong', timestamp: 1 }));
  ws.send(JSON.stringify({ type: 'response_required', response_id: 1, transcript: [{ role: 'agent', content: frames[0].content }, { role: 'user', content: 'How did September go?' }] }));
  const next = await call('GET', '/v1/jobs/next?wait=5');
  assert.equal(next.body.envelope.text, 'How did September go?');
  const posted = await call('POST', `/v1/jobs/${next.body.job_id}/result`, { reply_text: '2026-09: income $4,800.00, expenses $3,150.00. Data mode: fixture.' });
  assert.equal(posted.body.delivered, 'call');
  await until(() => frames.some((f) => f.response_id === 1 && f.content_complete));
  assert.deepEqual(frames.find((f) => f.type === 'ping_pong'), { type: 'ping_pong', timestamp: 1 });
  const turn = frames.filter((f) => f.response_id === 1);
  assert.equal(turn.at(-1).content, 'September 2026: income $4,800, expenses $3,150.');

  const { forCall } = await import('../src/voice.ts');
  // The v1 app's real reply to "Where is my money going?", as texted back at 3:11 PM.
  const long = '2026-09: income $4,800.00, expenses $3,150.00, savings $650.00, investments $400.00, retained cash $600.00. Net worth: $11,550.00. Data mode: fixture. Categories: Rent: $1,600.00; Groceries: $500.00; Dining: $300.00; Bills and subscriptions: $250.00; Other: $250.00; Transport: $250.00. Accounts: Demo Bank checking: $3,400.00; Demo Card credit_card: $900.00.';
  assert.equal(forCall(long), 'September 2026: income $4,800, expenses $3,150, savings $650, investments $400, retained cash $600. Net worth: $11,550. The rest is in Lana.');
  assert.equal(forCall('Saves $150.00/month.'), 'Saves $150 a month.');

  ws.send(JSON.stringify({ type: 'response_required', response_id: 2, transcript: [{ role: 'user', content: '(unintelligible audio)' }] }));
  await until(() => frames.some((f) => f.response_id === 2));
  assert.match(frames.find((f) => f.response_id === 2).content, /didn't catch that/);
  assert.equal((await call('GET', '/v1/jobs/next?wait=0')).status, 204, 'noise never becomes a phone job');
  ws.close();
});

test('a turn replayed after a reconnect gets an answer and does not crash the relay', async () => {
  for (let i = 0; i < 2; i++) {
    const { ws, frames, until } = await dialCall('call_replay', PHONE);
    ws.send(JSON.stringify({ type: 'response_required', response_id: 3, transcript: [{ role: 'user', content: 'Where is my money going?' }] }));
    const next = await call('GET', '/v1/jobs/next?wait=5');
    await call('POST', `/v1/jobs/${next.body.job_id}/result`, { reply_text: 'Net worth: $11,550.00.' });
    await until(() => frames.some((f) => f.content_complete));
    assert.equal(frames.find((f) => f.content_complete).content, 'Net worth: $11,550.');
    ws.close();
  }
  assert.equal((await fetch(`${BASE}/health`)).status, 200);
});

test('an unpaired caller is told to pair and the call ends', async () => {
  const { ws, frames, until } = await dialCall('call_test2', '+15550009999');
  ws.send(JSON.stringify({ type: 'response_required', response_id: 0, transcript: [] }));
  await until(() => frames.length >= 1);
  assert.equal(frames[0].end_call, true);
  ws.close();
});
