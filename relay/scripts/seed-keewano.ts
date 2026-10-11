// Backfills Keewano with swap-decision history (BUD-04) and workflow timings for the time receipt.
// The demo user rejected instant coffee three times, so get_swap_memory blocks that swap.
// Usage: KEEWANO_API_KEY=... KEEWANO_PAT=... node scripts/seed-keewano.ts
import { registerEvents, sendEntity, swapMemory, entityUuid } from '../src/keewano.ts';

const DAY = 86400;
const t0 = Math.floor(Date.now() / 1000) - 42 * DAY;

// Group ids must match the swap catalog in fixtures (Ashwin's lane).
const GROUPS = ['pantry_staples', 'detergent', 'coffee_beans', 'phone_plan', 'instant_coffee'];
const DEMO_USER = process.env.DEMO_USER || 'user_ashwin';
const demoHistory: [string, 'accepted' | 'rejected'][] = [
  ['instant_coffee', 'rejected'],
  ['pantry_staples', 'accepted'],
  ['instant_coffee', 'rejected'],
  ['coffee_beans', 'accepted'],
  ['detergent', 'accepted'],
  ['instant_coffee', 'rejected'],
  ['phone_plan', 'accepted'],
  ['coffee_beans', 'rejected'],
  ['pantry_staples', 'accepted'],
  ['coffee_beans', 'accepted'],
];

function decisions(history: [string, string][], start: number): [string, string, number][] {
  return history.flatMap(([g, d], i) => {
    const t = start + i * 4 * DAY + (i % 3) * 3600;
    return [['SwapGroup', g, t], ['SwapDecision', d, t + 30]] as [string, string, number][];
  });
}

// Deterministic pseudo-random so reruns produce the same population.
let seed = 42;
const rand = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);

console.log('register:', await registerEvents());
console.log(`${DEMO_USER} (${entityUuid(DEMO_USER)}):`, await sendEntity(DEMO_USER, decisions(demoHistory, t0)));

// A small population so Keewano reports show a trend: instant coffee is the swap people reject most.
for (let u = 0; u < 30; u++) {
  const history: [string, string][] = Array.from({ length: 6 }, () => {
    const g = GROUPS[Math.floor(rand() * GROUPS.length)];
    const rejectRate = g === 'instant_coffee' ? 0.75 : 0.2;
    return [g, rand() < rejectRate ? 'rejected' : 'accepted'];
  });
  await sendEntity(`synthetic_user_${u}`, decisions(history, t0 + Math.floor(rand() * 7 * DAY)));
}
console.log('population: 30 synthetic users');

// Workflow timings behind the time receipt: one entity per timed run, manual vs FWM.
// Placeholders until we time the real manual runs. Replace them with measured seconds.
const WORKFLOWS: [string, number, number][] = [
  ['month_review', 1500, 25],
  ['budget_swaps', 1200, 40],
  ['bill_split', 600, 35],
];
for (const [name, manual, fwm] of WORKFLOWS) {
  for (let r = 0; r < 8; r++) {
    for (const [mode, base] of [['manual', manual], ['fwm', fwm]] as const) {
      const t = t0 + Math.floor(rand() * 40 * DAY);
      const secs = Math.round(base * (0.8 + rand() * 0.4));
      await sendEntity(`run_${name}_${mode}_${r}`, [['WorkflowName', name, t], ['WorkflowMode', mode, t + 1], ['WorkflowSeconds', secs, t + 2]]);
    }
  }
}
console.log('workflow timings: 48 runs');

if (process.env.KEEWANO_PAT) {
  await new Promise((r) => setTimeout(r, 5000));
  console.log('swap memory check:', await swapMemory(DEMO_USER, GROUPS).catch((e) => `query failed (ingest may still be processing): ${e.message}`));
}
