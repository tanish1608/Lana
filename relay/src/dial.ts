// Dial adapter: inbound text/image/audio, outbound replies and result cards (SRS section 7, PLAT-01).
import { createHmac, timingSafeEqual } from 'node:crypto';
import { DialClient } from '@getdial/sdk';
import { db, now, id } from './store.ts';

const KEY = process.env.DIAL_API_KEY;
export const FROM = process.env.DIAL_NUMBER || '';
export const dial = KEY ? new DialClient({ apiKey: KEY, userAgent: 'fwm-relay/0.1' }) : null;

export type InboundMessage = {
  eventId: string;
  messageId: string;
  from: string;
  to: string | null;
  channel: string;
  body: string;
  media: { id: string; url: string; contentType: string }[];
  receivedAt: string;
  source?: string;
};

type Handler = (m: InboundMessage) => Promise<void>;

function fromEvent(ev: any): InboundMessage | null {
  if (ev?.type !== 'message.received' || !ev.data) return null;
  const d = ev.data;
  if (d.reaction) return null; // Tapbacks are not requests.
  return {
    eventId: ev.id,
    messageId: d.messageId,
    from: d.from,
    to: d.to,
    channel: d.channel,
    body: d.body || '',
    media: (d.media || []).map((m: any) => ({ id: m.id, url: m.url, contentType: m.contentType })),
    receivedAt: ev.createdAt || now(),
    source: d.source,
  };
}

// Live stream for low latency. It is presence-based, so `catchUp` and the webhook cover gaps.
export async function startStream(onMessage: Handler) {
  if (!dial) return;
  for (;;) {
    try {
      const conn = await dial.newEventsConnection();
      console.log('[dial] event stream connected');
      for await (const ev of conn) {
        if (process.env.DIAL_DEBUG) console.log('[dial] event', JSON.stringify(ev).slice(0, 600));
        const m = fromEvent(ev);
        if (m) await onMessage(m).catch((e) => console.error('[dial] inbound failed:', e.message));
      }
    } catch (e: any) {
      console.error('[dial] stream error:', e.message);
    }
    await new Promise((r) => setTimeout(r, 3000));
    await catchUp(onMessage).catch(() => {});
  }
}

// After a disconnect, replay recent inbound messages we have not seen. Dedup happens in the handler.
export async function catchUp(onMessage: Handler) {
  if (!dial) return;
  const msgs: any[] = await dial.listMessages();
  for (const m of msgs.filter((x) => x.direction === 'inbound').reverse()) {
    await onMessage({
      eventId: `msg:${m.id}`,
      messageId: m.id,
      from: m.from,
      to: m.to,
      channel: m.channel,
      body: m.body || '',
      media: (m.media || []).map((x: any) => ({ id: x.id, url: x.url, contentType: x.contentType })),
      receivedAt: m.createdAt || now(),
    }).catch(() => {});
  }
}

// Signed webhook deliveries (at-least-once). Header: X-Dial-Signature: t=<unix>,v1=<hex hmac of "t.body">.
export function verifyWebhook(rawBody: string, header: string | undefined): any | null {
  const secret = process.env.DIAL_WEBHOOK_SECRET;
  if (!secret || !header) return null;
  const parts = Object.fromEntries(header.split(',').map((p) => p.split('=')));
  const t = Number(parts.t);
  if (!t || Math.abs(Date.now() / 1000 - t) > 300) return null; // replay window
  const expected = createHmac('sha256', secret).update(`${t}.${rawBody}`).digest('hex');
  const got = Buffer.from(parts.v1 || '', 'hex');
  if (got.length !== expected.length / 2 || !timingSafeEqual(got, Buffer.from(expected, 'hex'))) return null;
  return fromEvent(JSON.parse(rawBody));
}

// Outbound send, idempotent per key (ACT-03). A timeout becomes delivery_unknown, never a blind retry.
export async function send(opts: { key: string; to: string; body: string; card?: { data: Uint8Array; contentType: string } }) {
  const existing = db.prepare('SELECT * FROM outbox WHERE idempotency_key = ?').get(opts.key) as any;
  if (existing && existing.delivery_state !== 'failed') return existing;
  const outboxId = existing?.outbox_id || id('out');
  if (!existing) {
    db.prepare(`INSERT INTO outbox (outbox_id, idempotency_key, to_number, body, has_card, delivery_state, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'dispatching', ?, ?)`).run(outboxId, opts.key, opts.to, opts.body, opts.card ? 1 : 0, now(), now());
  } else {
    db.prepare(`UPDATE outbox SET delivery_state = 'dispatching', updated_at = ? WHERE outbox_id = ?`).run(now(), outboxId);
  }
  if (!dial) {
    db.prepare(`UPDATE outbox SET delivery_state = 'failed', error = 'DIAL_API_KEY not set', updated_at = ? WHERE outbox_id = ?`).run(now(), outboxId);
    return db.prepare('SELECT * FROM outbox WHERE outbox_id = ?').get(outboxId);
  }
  try {
    const msg = await Promise.race([
      dial.sendMessage({
        to: opts.to,
        fromNumber: FROM,
        body: opts.body,
        ...(opts.card ? { media: [{ data: opts.card.data, contentType: opts.card.contentType, filename: 'fwm-card.png' }] } : {}),
      }),
      new Promise<never>((_, rej) => setTimeout(() => rej(Object.assign(new Error('send timeout'), { timeout: true })), 20_000)),
    ]);
    db.prepare(`UPDATE outbox SET provider_message_id = ?, delivery_state = 'sent', updated_at = ? WHERE outbox_id = ?`).run((msg as any).id, now(), outboxId);
  } catch (e: any) {
    const state = e.timeout ? 'delivery_unknown' : 'failed';
    db.prepare(`UPDATE outbox SET delivery_state = ?, error = ?, updated_at = ? WHERE outbox_id = ?`).run(state, String(e.message).slice(0, 300), now(), outboxId);
  }
  return db.prepare('SELECT * FROM outbox WHERE outbox_id = ?').get(outboxId);
}
