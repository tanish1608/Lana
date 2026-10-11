// Keewano as recommendation memory (SRS BUD-04, section 7). Narrow adapter: swap decisions in, blocked groups out.
// Event model per pseudonymous user UUID: SwapGroup(string) then SwapDecision(string: accepted | rejected).
import { createHash, randomUUID } from 'node:crypto';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { kvGet, kvSet, now } from './store.ts';

const INGEST = 'https://api.keewano.com/event/ingress/v1/json';
const PROJECT = process.env.KEEWANO_PROJECT_ID || '72ce4c09-50a8-4746-8baf-f5b0c40d2fd4';

// Append-only: never reorder or change a type.
export const CUSTOM_EVENTS = [
  { eventTypeId: 2100, name: 'SwapGroup', dataType: 'string' },
  { eventTypeId: 2101, name: 'SwapDecision', dataType: 'string' },
  { eventTypeId: 2102, name: 'WorkflowName', dataType: 'string' },
  { eventTypeId: 2103, name: 'WorkflowMode', dataType: 'string' },
  { eventTypeId: 2104, name: 'WorkflowSeconds', dataType: 'uint' },
];
const HASH = parseInt(createHash('sha256').update(JSON.stringify(CUSTOM_EVENTS)).digest('hex').slice(0, 8), 16) || 1;
const TYPE = Object.fromEntries(CUSTOM_EVENTS.map((e) => [e.name, e]));

async function post(path: string, body: unknown) {
  const res = await fetch(`${INGEST}/${path}`, {
    method: 'POST',
    headers: { 'k-token': process.env.KEEWANO_API_KEY || '', 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Keewano ${path} ${res.status}: ${text.slice(0, 200)}`);
  return text;
}

export async function registerEvents() {
  return post('custom', { customEventsHash: HASH, eventTypes: CUSTOM_EVENTS });
}

/** events: [name, value, unixSeconds][] for one entity (a UUID or a string id), in time order. */
export async function sendEntity(entity: string, events: [string, string | number, number][]) {
  return post('in', {
    dataSessionId: randomUUID(),
    batch: 1,
    customEventsHash: HASH,
    installId: entityUuid(entity),
    events: events.map(([name, data, ts]) => ({ eventTypeId: TYPE[name].eventTypeId, dataType: TYPE[name].dataType, timestamp: ts, data })),
  });
}

let mcp: Client | null = null;
async function client() {
  if (mcp) return mcp;
  const c = new Client({ name: 'fwm-relay', version: '0.1.0' });
  await c.connect(new StreamableHTTPClientTransport(new URL('https://api.keewano.com/mcp'), { requestInit: { headers: { 'k-token': process.env.KEEWANO_PAT || '' } } }));
  mcp = c;
  return c;
}

export async function sql(query: string): Promise<Record<string, unknown>[]> {
  const res: any = await (await client()).callTool({ name: 'run_sql_query', arguments: { projectId: PROJECT, sqlQuery: query } });
  const text = res.content?.find((c: any) => c.type === 'text')?.text || '';
  if (res.isError) throw new Error(text.slice(0, 300));
  const out = JSON.parse(text);
  const cols: string[] = (out.columns || []).map((c: any) => c.name ?? c);
  return (out.rows || []).map((r: any) => (Array.isArray(r) ? Object.fromEntries(cols.map((c, i) => [c, r[i]])) : r));
}

export type SwapMemory = {
  blocked_groups: string[];
  evidence_ids: string[];
  as_of: string;
  data_mode: 'live' | 'cached';
  query: string;
};

const quote = (s: string) => `'${s.replace(/[^a-z0-9_]/gi, '')}'`;
const isUuid = (s: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);

/** Keewano entities are UUIDs. Derive one from a string id with UUID v5 (URL namespace), as Keewano's quickstart does. */
export function entityUuid(name: string): string {
  if (isUuid(name)) return name.toLowerCase();
  const ns = Buffer.from('6ba7b8119dad11d180b400c04fd430c8', 'hex');
  const h = createHash('sha1').update(Buffer.concat([ns, Buffer.from(name)])).digest();
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const x = h.subarray(0, 16).toString('hex');
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

/** A group is blocked when this user's history rejects it more often than it accepts it. Falls back to the last good answer, labeled cached. */
// FILTER names the instants where SwapDecision has that value, so count(*) counts decisions (not carried-forward rows).
// GROUP BY reads the group in effect at each decision. count(col) FILTER is rejected as an unsupported aggregate.
export async function swapMemory(userId: string, groups: string[]): Promise<SwapMemory> {
  const userUuid = entityUuid(userId);
  const query = `SELECT "SwapGroup",
  count(*) FILTER (WHERE "SwapDecision" = 'rejected') AS rejected,
  count(*) FILTER (WHERE "SwapDecision" = 'accepted') AS accepted
FROM events
WHERE user_id = '${userUuid}' AND "SwapGroup" IN (${groups.map(quote).join(', ')})
GROUP BY "SwapGroup"`;
  const cacheKey = `swap:${userUuid}:${groups.slice().sort().join(',')}`;
  try {
    const rows = await sql(query);
    const blocked = rows.filter((r) => Number(r.rejected) > Number(r.accepted)).map((r) => String(r.SwapGroup));
    const result: SwapMemory = {
      blocked_groups: blocked,
      evidence_ids: blocked.map((g) => `keewano:${userUuid}:${g}`),
      as_of: now(),
      data_mode: 'live',
      query,
    };
    kvSet(cacheKey, result);
    return result;
  } catch (e) {
    const cached = kvGet<SwapMemory>(cacheKey);
    if (cached) return { ...cached, data_mode: 'cached' };
    throw e;
  }
}
