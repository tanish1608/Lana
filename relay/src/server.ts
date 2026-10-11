// FWM relay. Messaging in and out (Dial), a durable job queue the foreground phone pulls from (PLAT-02),
// approved reminder dispatch (SPLIT-08), and narrow sponsor adapters. It never calls a cloud LLM.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { db, now, id, demoNow, advanceClock } from './store.ts';
import { dial, FROM, send, startStream, catchUp, verifyWebhook, type InboundMessage } from './dial.ts';
import { swapMemory } from './keewano.ts';
import { canonical } from './canonical.ts';

const PORT = Number(process.env.PORT || 8787);
const PUBLIC_BASE = process.env.PUBLIC_BASE_URL || `http://localhost:${PORT}`;
const PAIRING_CODE = process.env.PAIRING_CODE || String(randomBytes(3).readUIntBE(0, 3) % 1_000_000).padStart(6, '0');
// Which phone numbers belong to which paired user: "+14085550101=user_ashwin,+1..."
const PAIRED_PHONES = Object.fromEntries((process.env.PAIRED_PHONES || '').split(',').filter(Boolean).map((p) => p.split('=').map((s) => s.trim())));
const FOREGROUND_MS = 20_000; // a device that polled this recently counts as open

// ---------- inbound ----------

const waiters: ((jobId: string) => void)[] = [];

async function onInbound(m: InboundMessage) {
  if (m.from === FROM) return;
  const dup = db.prepare('SELECT 1 FROM events WHERE event_id = ? OR provider_message_id = ?').get(m.eventId, m.messageId);
  if (dup) return;
  db.prepare('INSERT INTO events (event_id, provider_message_id, received_at) VALUES (?, ?, ?)').run(m.eventId, m.messageId, m.receivedAt);
  const user = PAIRED_PHONES[m.from];
  if (!user) {
    console.log(`[relay] ignoring message from unpaired ${m.from}`);
    return;
  }
  const jobId = id('job');
  const attachments = m.media.map((x) => {
    const attachmentId = id('att');
    const kind = x.contentType?.startsWith('image/') ? 'image' : x.contentType?.startsWith('audio/') ? 'audio' : 'other';
    db.prepare('INSERT INTO attachments (attachment_id, job_id, provider_url, content_type, kind) VALUES (?, ?, ?, ?, ?)').run(attachmentId, jobId, x.url, x.contentType, kind);
    return { attachment_id: attachmentId, kind, mime_type: x.contentType, url: `${PUBLIC_BASE}/v1/attachments/${attachmentId}` };
  });
  const envelope = {
    event_id: m.eventId,
    conversation_id: `conv_${createHash('sha256').update(m.from).digest('hex').slice(0, 12)}`,
    paired_user_id: user,
    channel: m.channel === 'imessage' ? 'imessage' : 'sms',
    received_at: m.receivedAt,
    text: m.body || null,
    attachments,
    provider_message_id: m.messageId,
  };
  db.prepare(`INSERT INTO jobs (job_id, event_id, paired_user_id, reply_to, envelope, state, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, 'queued', ?, ?)`).run(jobId, m.eventId, user, m.from, JSON.stringify(envelope), now(), now());
  console.log(`[relay] job ${jobId} queued (${m.channel}, ${m.media.length} attachment(s)) provider_message_id=${m.messageId}`);
  waiters.splice(0).forEach((w) => w(jobId));
  // NEEDS_FOREGROUND: if no phone is open, send one short nudge with an opaque link (PLAT-02, UI-03).
  setTimeout(() => nudgeIfIdle(jobId, user, m.from), 6000);
}

async function nudgeIfIdle(jobId: string, user: string, to: string) {
  const job = db.prepare('SELECT state, nudged FROM jobs WHERE job_id = ?').get(jobId) as any;
  if (!job || job.state !== 'queued' || job.nudged) return;
  const dev = db.prepare('SELECT MAX(last_seen) AS t FROM devices WHERE paired_user_id = ?').get(user) as any;
  if (dev?.t && Date.now() - dev.t < FOREGROUND_MS) return;
  db.prepare('UPDATE jobs SET nudged = 1, updated_at = ? WHERE job_id = ?').run(now(), jobId);
  await send({ key: `nudge:${jobId}`, to, body: `Got it. Open FWM to finish: fwm://job/${jobId}` });
}

// ---------- device auth and approvals ----------

function device(req: IncomingMessage) {
  const token = (req.headers.authorization || '').replace(/^Bearer /, '');
  const d = token && (db.prepare('SELECT * FROM devices WHERE device_token = ?').get(token) as any);
  if (d) db.prepare('UPDATE devices SET last_seen = ? WHERE device_token = ?').run(Date.now(), token);
  return d || null;
}

/** ACT-02: an approval is bound to the exact payload, a nonce and an expiry, and signed by the paired device after MFA. */
function checkApproval(dev: any, actionId: string, payload: unknown, approval: any): string | null {
  if (!approval) return 'missing approval';
  const payloadHash = createHash('sha256').update(canonical(payload)).digest('hex');
  if (approval.payload_hash !== payloadHash) return 'payload changed after approval';
  if (approval.action_id !== actionId) return 'approval is for a different action';
  if (!approval.expires_at || Date.parse(approval.expires_at) < Date.now()) return 'approval expired';
  const mac = createHmac('sha256', dev.approval_secret).update(`${actionId}.${payloadHash}.${approval.nonce}.${approval.expires_at}`).digest();
  const got = Buffer.from(String(approval.mac || ''), 'hex');
  if (got.length !== mac.length || !timingSafeEqual(got, mac)) return 'bad signature';
  try {
    db.prepare('INSERT INTO nonces (nonce, used_at) VALUES (?, ?)').run(String(approval.nonce), now());
  } catch {
    return 'approval already used';
  }
  return null;
}

// ---------- reminders ----------

setInterval(async () => {
  const due = db.prepare(`SELECT * FROM reminders WHERE status = 'scheduled' AND due_at <= ?`).all(demoNow()) as any[];
  for (const r of due) {
    db.prepare(`UPDATE reminders SET status = 'dispatching', updated_at = ? WHERE reminder_id = ?`).run(now(), r.reminder_id);
    const out: any = await send({ key: `reminder:${r.reminder_id}`, to: r.to_number, body: r.body });
    const status = out.delivery_state === 'sent' ? 'sent' : out.delivery_state === 'delivery_unknown' ? 'delivery_unknown' : 'failed';
    db.prepare(`UPDATE reminders SET status = ?, outbox_id = ?, updated_at = ? WHERE reminder_id = ?`).run(status, out.outbox_id, now(), r.reminder_id);
    console.log(`[relay] reminder ${r.reminder_id} → ${status}`);
  }
}, 2000);

// ---------- HTTP ----------

async function readBody(req: IncomingMessage) {
  let s = '';
  for await (const c of req) s += c;
  return s;
}
function json(res: ServerResponse, code: number, body: unknown) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}
const err = (res: ServerResponse, code: number, errCode: string, message: string, retryable = false) =>
  json(res, code, { error: { code: errCode, retryable, user_message: message } });

function claimNext(user: string) {
  const job = db.prepare(`SELECT * FROM jobs WHERE paired_user_id = ? AND (state = 'queued' OR (state = 'claimed' AND lease_until < ?)) ORDER BY created_at LIMIT 1`).get(user, Date.now()) as any;
  if (!job) return null;
  db.prepare(`UPDATE jobs SET state = 'claimed', lease_until = ?, retry_count = retry_count + ?, updated_at = ? WHERE job_id = ?`)
    .run(Date.now() + 90_000, job.state === 'claimed' ? 1 : 0, now(), job.job_id);
  return { job_id: job.job_id, envelope: JSON.parse(job.envelope) };
}

const routes: [string, RegExp, (req: IncomingMessage, res: ServerResponse, m: RegExpMatchArray, dev: any) => Promise<void> | void, boolean][] = [
  ['GET', /^\/health$/, (_q, res) => json(res, 200, { ok: true, dial: !!dial, from: FROM || null, demo_now: new Date(demoNow()).toISOString() }), false],

  ['POST', /^\/v1\/pair$/, async (req, res) => {
    const { code, paired_user_id } = JSON.parse((await readBody(req)) || '{}');
    if (code !== PAIRING_CODE) return err(res, 401, 'AUTH_REQUIRED', 'That pairing code is wrong.');
    const token = randomBytes(24).toString('hex');
    const secret = randomBytes(32).toString('hex');
    const user = paired_user_id || Object.values(PAIRED_PHONES)[0] || 'user_ashwin';
    db.prepare('INSERT INTO devices (device_token, paired_user_id, approval_secret, last_seen) VALUES (?, ?, ?, ?)').run(token, user, secret, Date.now());
    json(res, 200, { device_token: token, approval_secret: secret, paired_user_id: user });
  }, false],

  // Long poll: the foreground phone waits here for its next job.
  ['GET', /^\/v1\/jobs\/next/, async (req, res, _m, dev) => {
    const wait = Math.min(Number(new URL(req.url!, 'http://x').searchParams.get('wait') || 25), 30) * 1000;
    let next = claimNext(dev.paired_user_id);
    if (!next) {
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, wait);
        waiters.push(() => { clearTimeout(t); resolve(); });
      });
      next = claimNext(dev.paired_user_id);
    }
    if (!next) { res.writeHead(204); res.end(); return; }
    json(res, 200, next);
  }, true],

  // Attachment bytes, proxied so the phone never needs Dial's media URL.
  ['GET', /^\/v1\/attachments\/(att_\w+)$/, async (_req, res, m, dev) => {
    const a = db.prepare('SELECT a.*, j.paired_user_id FROM attachments a JOIN jobs j ON j.job_id = a.job_id WHERE attachment_id = ?').get(m[1]) as any;
    if (!a || a.paired_user_id !== dev.paired_user_id) return err(res, 404, 'INVALID_ARGUMENTS', 'No such attachment.');
    const r = await fetch(a.provider_url);
    if (!r.ok) return err(res, 502, 'PROVIDER_UNAVAILABLE', 'Could not fetch the attachment.', true);
    res.writeHead(200, { 'Content-Type': a.content_type || 'application/octet-stream' });
    res.end(Buffer.from(await r.arrayBuffer()));
  }, true],

  // The phone's answer. Idempotent per job: a repeated submit never sends twice.
  ['POST', /^\/v1\/jobs\/(job_\w+)\/result$/, async (req, res, m, dev) => {
    const job = db.prepare('SELECT * FROM jobs WHERE job_id = ?').get(m[1]) as any;
    if (!job || job.paired_user_id !== dev.paired_user_id) return err(res, 404, 'INVALID_ARGUMENTS', 'No such job.');
    const body = JSON.parse((await readBody(req)) || '{}');
    if (!body.reply_text) return err(res, 400, 'INVALID_ARGUMENTS', 'reply_text is required.');
    const card = body.card?.base64 ? { data: new Uint8Array(Buffer.from(body.card.base64, 'base64')), contentType: body.card.content_type || 'image/png' } : undefined;
    db.prepare(`UPDATE jobs SET state = 'answered', result_id = ?, updated_at = ? WHERE job_id = ?`).run(body.provenance?.result_id || null, now(), job.job_id);
    const out = await send({ key: `reply:${job.job_id}`, to: job.reply_to, body: body.reply_text, card });
    json(res, 200, { job_id: job.job_id, outbox: out });
  }, true],

  // Reminder after an approved split (SPLIT-08). At most one per action; paid/disputed cancels it.
  ['POST', /^\/v1\/reminders$/, async (req, res, _m, dev) => {
    const b = JSON.parse((await readBody(req)) || '{}');
    const payload = { action_id: b.action_id, contact_id: b.contact_id, to: b.to, body: b.body, due_at: b.due_at };
    const problem = checkApproval(dev, b.action_id, payload, b.approval);
    if (problem) return err(res, 403, 'AUTH_REQUIRED', `Not sent: ${problem}.`);
    const existing = db.prepare('SELECT * FROM reminders WHERE action_id = ?').get(b.action_id);
    if (existing) return json(res, 200, existing);
    const rid = id('rem');
    db.prepare(`INSERT INTO reminders (reminder_id, action_id, split_id, contact_id, to_number, body, due_at, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'scheduled', ?, ?)`).run(rid, b.action_id, b.split_id || null, b.contact_id, b.to, b.body, Date.parse(b.due_at), now(), now());
    json(res, 201, db.prepare('SELECT * FROM reminders WHERE reminder_id = ?').get(rid));
  }, true],

  ['POST', /^\/v1\/reminders\/(rem_\w+)\/status$/, async (req, res, m) => {
    const { status } = JSON.parse((await readBody(req)) || '{}');
    if (!['paid', 'disputed', 'cancelled'].includes(status)) return err(res, 400, 'INVALID_ARGUMENTS', 'status must be paid, disputed or cancelled.');
    db.prepare(`UPDATE reminders SET status = ?, updated_at = ? WHERE reminder_id = ? AND status = 'scheduled'`).run(status, now(), m[1]);
    json(res, 200, db.prepare('SELECT * FROM reminders WHERE reminder_id = ?').get(m[1]));
  }, true],

  ['POST', /^\/v1\/clock\/advance$/, async (req, res) => {
    const { seconds } = JSON.parse((await readBody(req)) || '{}');
    advanceClock(Number(seconds || 0) * 1000);
    json(res, 200, { demo_now: new Date(demoNow()).toISOString() });
  }, true],

  ['GET', /^\/v1\/swap-memory/, async (req, res) => {
    const q = new URL(req.url!, 'http://x').searchParams;
    try {
      json(res, 200, await swapMemory(q.get('user_id') || '', (q.get('groups') || '').split(',').filter(Boolean)));
    } catch (e: any) {
      err(res, 502, 'PROVIDER_UNAVAILABLE', `Keewano is unavailable: ${e.message}`, true);
    }
  }, true],

  // Integration evidence for T09: provider IDs for every inbound and outbound message.
  ['GET', /^\/v1\/evidence$/, (_req, res, _m, dev) => json(res, 200, {
    jobs: db.prepare('SELECT job_id, event_id, state, retry_count, result_id, created_at FROM jobs WHERE paired_user_id = ? ORDER BY created_at DESC LIMIT 50').all(dev.paired_user_id),
    outbox: db.prepare('SELECT outbox_id, idempotency_key, provider_message_id, delivery_state, error, created_at FROM outbox ORDER BY created_at DESC LIMIT 50').all(),
    reminders: db.prepare('SELECT reminder_id, action_id, contact_id, due_at, status, outbox_id FROM reminders ORDER BY created_at DESC LIMIT 50').all(),
  }), true],

  // Dev and demo fallback: inject an inbound message as if Dial delivered it. Off unless RELAY_DEV=1.
  ['POST', /^\/dev\/inbound$/, async (req, res) => {
    if (process.env.RELAY_DEV !== '1') return err(res, 404, 'INVALID_ARGUMENTS', 'Not found.');
    const b = JSON.parse((await readBody(req)) || '{}');
    const eventId = b.event_id || id('evt');
    await onInbound({ eventId, messageId: b.message_id || `dev:${eventId}`, from: b.from, to: FROM || null, channel: b.channel || 'imessage', body: b.text || '', media: b.media || [], receivedAt: now(), source: 'dev' });
    json(res, 200, { event_id: eventId });
  }, false],

  ['POST', /^\/dial\/webhook$/, async (req, res) => {
    const raw = await readBody(req);
    const msg = verifyWebhook(raw, req.headers['x-dial-signature'] as string | undefined);
    if (!msg) return err(res, 401, 'AUTH_REQUIRED', 'Bad signature.');
    await onInbound(msg);
    json(res, 200, { ok: true });
  }, false],
];

createServer(async (req, res) => {
  try {
    const path = new URL(req.url!, 'http://x').pathname;
    for (const [method, re, handler, auth] of routes) {
      const m = path.match(re);
      if (!m || req.method !== method) continue;
      const dev = auth ? device(req) : null;
      if (auth && !dev) return err(res, 401, 'AUTH_REQUIRED', 'Pair this device first.');
      return await handler(req, res, m, dev);
    }
    err(res, 404, 'INVALID_ARGUMENTS', 'Not found.');
  } catch (e: any) {
    console.error('[relay]', e);
    err(res, 500, 'PROVIDER_UNAVAILABLE', e.message, true);
  }
}).listen(PORT, () => {
  console.log(`FWM relay on :${PORT}  dial=${dial ? FROM : 'off'}  pairing code=${PAIRING_CODE}  paired phones=${Object.keys(PAIRED_PHONES).length}`);
  catchUp(onInbound).catch((e) => console.error('[dial] catch-up failed:', e.message));
  startStream(onInbound);
});

export { onInbound };
