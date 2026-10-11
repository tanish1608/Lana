// Lana action executor, first version. Kept as the recorded baseline: it applies whatever action arrives.
// No approval check, no dedupe, no retry, no idempotency key.
const task = JSON.parse(process.env.WORLDS_TASK_JSON);
const base = process.env.WORLDS_BASE_URL;
const auth = { authorization: 'Bearer ' + process.env.WORLDS_API_KEY };
const actions = JSON.parse(task.mission.prompt.split('LANA_ACTIONS ')[1]);

function form(obj, prefix = '', out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(obj)) {
    const name = prefix ? `${prefix}[${k}]` : k;
    if (v !== null && typeof v === 'object') form(v, name, out);
    else out.append(name, String(v));
  }
  return out;
}
async function call(method, path, params) {
  const init = { method, headers: { ...auth } };
  if (params) {
    init.headers['content-type'] = 'application/x-www-form-urlencoded';
    init.body = form(params).toString();
  }
  const res = await fetch(base + path, init);
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

for (const a of actions) {
  const sub = await call('GET', `/v1/subscriptions/${a.subscription}`);
  await call('POST', `/v1/subscriptions/${a.subscription}`, {
    items: { 0: { id: sub.items.data[0].id, price: a.to_price } },
    proration_behavior: a.proration_behavior,
  });
  await call('PUT', '/api/v2/tickets/1.json', {
    ticket: {
      status: 'solved',
      tags: ['lana', 'swap', 'swap_applied'],
      comment: { body: `Switched ${a.subscription} to the 30 GB plan. You save $${(a.saving_cents / 100).toFixed(2)}/mo.`, public: true },
    },
  });
}
console.log(`applied ${actions.length} action(s)`);
