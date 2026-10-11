// Lana action executor. Runs money actions the user approved on their phone. No model runs here.
// Changes from executor-v1.mjs, each driven by a failing Sparta run:
//   1. verify the approval against the exact payload before touching billing (swap-not-approved, swap-tampered)
//   2. apply each action_id once: the subscription carries lana_action_id, read before writing (swap-redelivered)
//   3. bounded retries with a stable Idempotency-Key; read state before retrying the ticket reply (interruption)
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

const SECRET = process.env.LANA_APPROVAL_SECRET || 'sparta-demo-device-secret';
const task = JSON.parse(process.env.WORLDS_TASK_JSON);
const base = process.env.WORLDS_BASE_URL;
const auth = { authorization: 'Bearer ' + process.env.WORLDS_API_KEY };
const actions = JSON.parse(task.mission.prompt.split('LANA_ACTIONS ')[1]);

const canonical = (v) =>
  Array.isArray(v) ? `[${v.map(canonical).join(',')}]`
  : v && typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`
  : JSON.stringify(v);

/** Same check as the relay (relay/src/server.ts checkApproval). Returns a reason, or null if valid. */
function approvalProblem(action) {
  const { approval, ...payload } = action;
  if (!approval) return 'not approved';
  const hash = createHash('sha256').update(canonical(payload)).digest('hex');
  if (approval.payload_hash !== hash || approval.action_id !== payload.action_id) return 'changed after approval';
  if (Date.parse(approval.expires_at) < Date.now()) return 'approval expired';
  const mac = createHmac('sha256', SECRET).update(`${payload.action_id}.${hash}.${approval.nonce}.${approval.expires_at}`).digest();
  const got = Buffer.from(String(approval.mac), 'hex');
  if (got.length !== mac.length || !timingSafeEqual(got, mac)) return 'bad signature';
  return null;
}

function form(obj, prefix = '', out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(obj)) {
    const name = prefix ? `${prefix}[${k}]` : k;
    if (v !== null && typeof v === 'object') form(v, name, out);
    else out.append(name, String(v));
  }
  return out;
}

/** Up to 3 attempts on 429/5xx. Writes reuse one Idempotency-Key, so a retry can never apply twice.
 *  `beforeRetry` reads state first and returns true if the write already landed. */
async function call(method, path, params, { key, beforeRetry } = {}) {
  const init = { method, headers: { ...auth } };
  if (params) {
    init.headers['content-type'] = 'application/x-www-form-urlencoded';
    init.body = form(params).toString();
  }
  if (key) init.headers['idempotency-key'] = key;
  for (let attempt = 1; ; attempt++) {
    if (attempt > 1 && beforeRetry && (await beforeRetry())) return null;
    const res = await fetch(base + path, { ...init, signal: AbortSignal.timeout(10_000) });
    const text = await res.text();
    if (res.ok) return text ? JSON.parse(text) : null;
    if ((res.status === 429 || res.status >= 500) && attempt < 3) {
      console.log(`${method} ${path}: HTTP ${res.status}, retrying`);
      await new Promise((r) => setTimeout(r, 100 * attempt));
      continue;
    }
    throw new Error(`${method} ${path}: HTTP ${res.status} ${text.slice(0, 200)}`);
  }
}

const replied = async (ref) => (await call('GET', '/api/v2/tickets/1/comments.json')).comments.some((c) => c.body.includes(ref));
async function reply(ticket, body, ref) {
  await call('PUT', '/api/v2/tickets/1.json', { ticket: { ...ticket, comment: { body: `${body} (ref ${ref})`, public: true } } },
    { beforeRetry: () => replied(ref) });
}

for (const a of actions) {
  const problem = approvalProblem(a);
  if (problem) {
    console.log(`${a.action_id}: not applied (${problem})`);
    if (await replied(a.action_id)) continue;
    await reply({ status: 'pending' }, `Nothing changed on your phone plan. Lana needs your approval in the app before switching plans (${problem}).`, a.action_id);
    continue;
  }
  const sub = await call('GET', `/v1/subscriptions/${a.subscription}`);
  if (sub.metadata?.lana_action_id === a.action_id) {
    console.log(`${a.action_id}: already applied, skipping`);
    continue;
  }
  await call('POST', `/v1/subscriptions/${a.subscription}`, {
    items: { 0: { id: sub.items.data[0].id, price: a.to_price } },
    proration_behavior: a.proration_behavior,
    metadata: { lana_action_id: a.action_id },
  }, { key: `lana-${a.action_id}` });
  const tags = [...new Set([...(await call('GET', '/api/v2/tickets/1.json')).ticket.tags, 'swap_applied'])];
  await reply({ status: 'solved', tags }, `Switched ${a.subscription} to the 30 GB plan. You save $${(a.saving_cents / 100).toFixed(2)}/mo starting next renewal.`, a.action_id);
  console.log(`${a.action_id}: applied`);
}
