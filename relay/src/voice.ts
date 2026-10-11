// Calls through Dial Self-Hosted, LLM variant. Dial runs the call, speech to text and the voice, and asks us what to
// say next. Each caller turn becomes a phone job, so the paired iPhone writes the answer, as it does for texts.
import type { Server, IncomingMessage } from 'node:http';
import type { Duplex } from 'node:stream';
import { createHash } from 'node:crypto';
import WebSocket from 'ws';
import { parseDialMessage, serializeServerMessage, verifyDialSignature } from '@getdial/sdk';
import { db, now, id } from './store.ts';

const SECRET = process.env.DIAL_SELF_HOSTED_SECRET || '';
const TURN_MS = 25_000;
const answers = new Map<string, (text: string) => void>();

type Deps = {
  pairedUser: (phone: string) => string | undefined;
  phoneOpen: (user: string) => boolean;
  enqueued: (jobId: string) => void;
};

/** The job result route calls this; true means the job was a call turn and must not go out as SMS. */
export function answerCall(jobId: string, replyText: string): boolean {
  const done = answers.get(jobId);
  if (done) done(replyText);
  return (db.prepare('SELECT reply_to FROM jobs WHERE job_id = ?').get(jobId) as any)?.reply_to?.startsWith('call:') ?? false;
}

/** Engine replies are written for a screen. Read aloud, "2026-09" and ".00" and the data-mode tag get in the way. */
export function speakable(text: string): string {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return text
    .replace(/\b(\d{4})-(\d{2})\b(?!-)/g, (s, y, m) => (months[Number(m) - 1] ? `${months[Number(m) - 1]} ${y}` : s))
    .replace(/(\$[\d,]+)\.00\b/g, '$1')
    .replace(/\s*Data mode: \w+\.?/g, '')
    .replace(/[—–]/g, ',')
    .trim();
}

export function attachVoice(server: Server, deps: Deps) {
  const wss = new WebSocket.Server({ noServer: true });
  server.on('upgrade', (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    const m = (req.url || '').match(/^\/dial\/voice\/([\w-]+)$/);
    const signed = SECRET ? verifyDialSignature(SECRET, String(req.headers['x-dial-signature'] || ''), m?.[1] || '') : process.env.RELAY_DEV === '1';
    if (!m || !signed) {
      socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => onCall(ws, m[1], deps));
  });
}

function onCall(ws: WebSocket, callId: string, deps: Deps) {
  let user: string | undefined;
  let caller = '';
  let latest = -1; // a newer response_required supersedes the one in flight
  const say = (responseId: number, content: string, complete = true, endCall = false) => {
    if (responseId !== latest || ws.readyState !== WebSocket.OPEN) return;
    ws.send(serializeServerMessage({ type: 'response', response_id: responseId, content, content_complete: complete, ...(endCall ? { end_call: true } : {}) }));
  };

  ws.on('message', async (raw) => {
    let msg;
    try { msg = parseDialMessage(raw.toString()); } catch { return; }
    if (msg.type === 'ping_pong') {
      ws.send(serializeServerMessage({ type: 'ping_pong', timestamp: msg.timestamp }));
    } else if (msg.type === 'call_connected') {
      caller = msg.from;
      user = deps.pairedUser(msg.from);
      console.log(`[voice] call ${callId} from ${msg.from} ${user ? `as ${user}` : '(unpaired)'}`);
    } else if (msg.type === 'response_required') {
      const turn = (latest = msg.response_id);
      const heard = [...msg.transcript].reverse().find((t) => t.role === 'user')?.content.trim();
      if (!user) return say(turn, "This number isn't paired with Lana yet. Pair it in the Lana app, then call back.", true, true);
      if (!heard) return say(turn, 'Hi, this is Lana. Ask me about your money.');
      if (!deps.phoneOpen(user)) return say(turn, 'Open Lana on your iPhone, then ask me again. Your phone works out the answer, not me.');
      const jobId = id('job');
      const envelope = {
        event_id: `evt_${callId}_${turn}`,
        conversation_id: `conv_${createHash('sha256').update(caller).digest('hex').slice(0, 12)}`,
        paired_user_id: user,
        // The v1 app decodes only imessage, sms and app, so a call turn travels as sms; reply_to marks it as a call.
        channel: 'sms',
        received_at: new Date().toISOString(),
        text: heard,
        attachments: [],
      };
      db.prepare(`INSERT INTO jobs (job_id, event_id, paired_user_id, reply_to, envelope, state, created_at, updated_at)
                  VALUES (?, ?, ?, ?, ?, 'queued', ?, ?)`).run(jobId, envelope.event_id, user, `call:${callId}`, JSON.stringify(envelope), now(), now());
      console.log(`[voice] job ${jobId} for turn ${turn}: ${heard}`);
      deps.enqueued(jobId);
      say(turn, 'One sec. ', false);
      const reply = await new Promise<string | null>((resolve) => {
        const t = setTimeout(() => resolve(null), TURN_MS);
        answers.set(jobId, (text) => { clearTimeout(t); resolve(text); });
      });
      answers.delete(jobId);
      say(turn, reply ? speakable(reply) : "Your phone is still working on it. The answer will be waiting in Lana.");
    }
  });
  ws.on('close', () => console.log(`[voice] call ${callId} closed`));
}
