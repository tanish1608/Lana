// Durable relay state (SRS ACT-03, PLAT-02): every inbound event, job, outbound send and reminder is
// persisted before it is acknowledged or acted on. One SQLite file; safe to restart at any point.
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

mkdirSync('data', { recursive: true });
export const db = new DatabaseSync(process.env.RELAY_DB || 'data/relay.db');
db.exec(`
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS events (event_id TEXT PRIMARY KEY, provider_message_id TEXT, received_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS jobs (
  job_id TEXT PRIMARY KEY, event_id TEXT UNIQUE NOT NULL, paired_user_id TEXT NOT NULL, reply_to TEXT NOT NULL,
  envelope TEXT NOT NULL, state TEXT NOT NULL, lease_until INTEGER, retry_count INTEGER NOT NULL DEFAULT 0,
  nudged INTEGER NOT NULL DEFAULT 0, result_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS attachments (attachment_id TEXT PRIMARY KEY, job_id TEXT, provider_url TEXT NOT NULL, content_type TEXT, kind TEXT);
CREATE TABLE IF NOT EXISTS outbox (
  outbox_id TEXT PRIMARY KEY, idempotency_key TEXT UNIQUE NOT NULL, to_number TEXT NOT NULL, body TEXT NOT NULL,
  has_card INTEGER NOT NULL DEFAULT 0, provider_message_id TEXT, delivery_state TEXT NOT NULL, error TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS devices (device_token TEXT PRIMARY KEY, paired_user_id TEXT NOT NULL, approval_secret TEXT NOT NULL, last_seen INTEGER);
CREATE TABLE IF NOT EXISTS reminders (
  reminder_id TEXT PRIMARY KEY, action_id TEXT UNIQUE NOT NULL, split_id TEXT, contact_id TEXT NOT NULL, to_number TEXT NOT NULL,
  body TEXT NOT NULL, due_at INTEGER NOT NULL, status TEXT NOT NULL, outbox_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS nonces (nonce TEXT PRIMARY KEY, used_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS timings (run_id TEXT PRIMARY KEY, workflow TEXT NOT NULL, mode TEXT NOT NULL, seconds INTEGER NOT NULL, keewano TEXT, created_at TEXT NOT NULL);
`);

export const now = () => new Date().toISOString();
export const id = (prefix: string) => `${prefix}_${randomUUID().replace(/-/g, '').slice(0, 16)}`;

export function kvGet<T>(k: string): T | null {
  const row = db.prepare('SELECT v FROM kv WHERE k = ?').get(k) as { v: string } | undefined;
  return row ? (JSON.parse(row.v) as T) : null;
}
export function kvSet(k: string, v: unknown) {
  db.prepare('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v').run(k, JSON.stringify(v));
}

// Demo clock (SPLIT-08): reminders fire against this, never against token or MFA expiry.
export function demoNow(): number {
  return Date.now() + (kvGet<number>('clock_offset_ms') || 0);
}
export function advanceClock(ms: number) {
  kvSet('clock_offset_ms', (kvGet<number>('clock_offset_ms') || 0) + ms);
}
