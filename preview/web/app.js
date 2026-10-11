// Lana companion app: interactive browser preview of the three demo journeys. Not the native app.
// Numbers come from fixtures/seed-v1.json through engine-port.js (tested against FWMCore's golden
// tests). preview-data.js holds the few labeled stand-ins the shared fixtures don't have yet.
(function () {
  "use strict";
  const P = window.LanaPreview, E = window.FWMEnginePort;
  const $ = (s, r = document) => r.querySelector(s);
  const main = $("#main");
  let DS; // seed dataset

  // ---------- formatting (display boundary only) ----------
  function fmt(c, opts = {}) {
    const neg = c < 0, a = Math.abs(c), whole = a % 100 === 0 && !opts.cents;
    const s = (a / 100).toLocaleString("en-US", { minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: whole ? 0 : 2 });
    return (neg ? "−" : "") + (opts.plus && !neg ? "+" : "") + "$" + s;
  }
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (m) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[m]));
  const sum = (xs, f = (x) => x) => xs.reduce((a, x) => a + f(x), 0);
  const dateLabel = (iso) => new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "America/Los_Angeles" });
  const monthLabel = (p) => new Date(p + "-15T12:00:00").toLocaleDateString("en-US", { month: "long", year: "numeric" });
  const phoneFmt = (p) => { const d = String(p).replace(/\D/g, "").slice(-10); return d.length === 10 ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : p; };
  const KIND = { checking: "Checking", savings: "Savings", brokerage: "Brokerage", credit_card: "Credit card", student_loan: "Student loan" };

  // ---------- state ----------
  let S;
  function initialState() {
    const ex = DS.split_example;
    return {
      tab: "money",
      money: { period: "2026-09", view: "flow" },
      budget: { accepted: Object.fromEntries([...P.budget.swaps, ...P.budget.habits].map((x) => [x.id, true])), memoryOn: true, adopted: null, busy: false },
      split: {
        step: 0, receipt: false, voice: false, upload: null,
        tip: P.split.ocr_misread.read, tipFixed: false,
        owners: Object.fromEntries(Object.entries(ex.assignments).map(([item, who]) => [item, who.length > 1 ? "shared" : who[0]])),
        req: {}, reminders: {}, clock: 0, disputed: {}
      },
      vault: { stage: "locked", revealed: {}, err: "", lockAt: 0 },
      log: []
    };
  }
  function logAction(text, kind = "approved") { S.log.unshift({ text, kind, at: S.split.clock ? "Oct 12 (demo clock)" : "Oct 11" }); }

  // ---------- shell ----------
  const ICONS = {
    money: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 19V9M10 19V5M16 19v-7M22 19H2"/></svg>',
    budget: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 3.5V12l6 4.5"/></svg>',
    split: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h12v18l-3-2-3 2-3-2-3 2z"/><path d="M9 8h6M9 12h6"/></svg>',
    vault: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="4" y="10" width="16" height="11" rx="2.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>'
  };
  const TABS = [["money", "Money"], ["budget", "Budget"], ["split", "Split"], ["vault", "Vault"]];
  function renderNav() { $("#nav").innerHTML = TABS.map(([id, l]) => `<button data-tab="${id}" ${S.tab === id ? 'aria-current="page"' : ""}>${ICONS[id]}${l}</button>`).join(""); }
  function render() {
    renderNav();
    let v;
    try { v = { money: viewMoney, budget: viewBudget, split: viewSplit, vault: viewVault }[S.tab](); }
    catch (e) { console.error(e); v = `<div class="card" style="margin-top:20px"><span class="tag bad">Something went wrong</span><p>${esc(e.message)}</p><button class="btn ghost" data-reset>Reset demo</button></div>`; }
    main.innerHTML = `<div class="fade-in">${v}</div>`;
    requestAnimationFrame(() => document.querySelectorAll("[data-w]").forEach((el) => (el.style.width = el.dataset.w + "%")));
  }
  function top() { main.scrollTop = 0; window.scrollTo(0, 0); }
  function go(tab) { S.tab = tab; top(); render(); }
  let toastT;
  function toast(t) { const el = $("#toast"); el.textContent = t; el.classList.add("show"); clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove("show"), 2400); }
  function sheet(html) {
    closeSheet();
    const bg = document.createElement("div"); bg.className = "sheet-bg"; bg.id = "sheet";
    bg.innerHTML = `<div class="sheet" role="dialog" aria-modal="true"><div class="grab"></div>${html}</div>`;
    bg.addEventListener("click", (e) => { if (e.target === bg) closeSheet(); });
    $("#phone").appendChild(bg); requestAnimationFrame(() => bg.classList.add("open"));
  }
  function closeSheet() { const s = $("#sheet"); if (s) s.remove(); }
  const bubbles = (me, lana) => `<div class="msg"><div class="via">From Messages</div><div class="bubble me">${esc(me)}</div>${lana ? `<div class="bubble lana">${lana}</div>` : ""}</div>`;

  // ======================= JOURNEY 1: MONEY =======================
  const mvCache = {};
  const mv = (p) => (mvCache[p] ||= E.moneyView(DS, p));
  const txById = () => Object.fromEntries(DS.transactions.map((t) => [t.transaction_id, t]));
  function periods() {
    const ks = new Set(DS.transactions.map((t) => E.monthKey(t.posted_at, DS.user.timezone)));
    ks.add(E.monthKey(DS.demo_clock, DS.user.timezone));
    return [...ks].sort();
  }
  const snapshotMonth = () => E.monthKey(DS.as_of, DS.user.timezone);

  function flowSVG(f) {
    const W = 340, H = 214, top = 4, gap = 9, nodeW = 12, rx = 172;
    const scale = (H - gap * 3) / f.net_income_cents;
    const outs = [
      { k: "expenses", label: "Expenses", v: f.expenses_cents, c: "var(--goes)" },
      { k: "savings", label: "Savings", v: f.to_savings_cents, c: "var(--accent)" },
      { k: "investments", label: "Investing", v: f.to_investments_cents, c: "var(--accent-2)" },
      { k: "retained", label: "Kept in checking", v: f.retained_cash_cents, c: "var(--accent-3)" }
    ];
    let ly = top, ry = top, paths = "", nodes = "", labels = "";
    const cys = [];
    outs.forEach((o, i) => {
      const h = Math.max(o.v * scale, 2), x0 = nodeW, x1 = rx, mx = (x0 + x1) / 2;
      paths += `<path d="M${x0},${ly} C${mx},${ly} ${mx},${ry} ${x1},${ry} L${x1},${ry + h} C${mx},${ry + h} ${mx},${ly + h} ${x0},${ly + h} Z" fill="${o.c}" opacity="0"><animate attributeName="opacity" from="0" to=".55" dur=".6s" begin="${0.1 + i * 0.14}s" fill="freeze"/></path>`;
      nodes += `<rect x="${rx}" y="${ry}" width="${nodeW}" height="${h}" rx="3" fill="${o.c}"/>`;
      cys.push(ry + h / 2);
      ly += h; ry += h + gap;
    });
    // Keep labels readable when small flows sit close together: at least 34px apart.
    let last = -Infinity;
    outs.forEach((o, i) => {
      const y = Math.max(cys[i], last + 34); last = y;
      if (Math.abs(y - cys[i]) > 2) labels += `<path d="M${rx + nodeW + 2},${cys[i]} L${rx + nodeW + 7},${y - 5}" stroke="var(--ink-3)" fill="none"/>`;
      labels += `<text x="${rx + nodeW + 10}" y="${y - 1}" class="lab">${o.label}</text><text x="${rx + nodeW + 10}" y="${y + 14}" class="amt num">${fmt(o.v)}</text>`;
    });
    const Hs = Math.max(H, last + 22);
    nodes += `<rect x="0" y="${top}" width="${nodeW}" height="${ly - top}" rx="3" fill="var(--ink)"/>`;
    return `<svg class="flow" viewBox="0 0 ${W} ${Hs + 18}" width="100%" role="img" aria-label="Income of ${fmt(f.net_income_cents)} flows to expenses ${fmt(f.expenses_cents)}, savings ${fmt(f.to_savings_cents)}, investing ${fmt(f.to_investments_cents)} and kept in checking ${fmt(f.retained_cash_cents)}">${paths}${nodes}${labels}<text x="0" y="${Hs + 16}" class="lab">Income ${fmt(f.net_income_cents)}</text></svg>`;
  }

  function viewMoney() {
    const pid = S.money.period, v = mv(pid), f = v.flow, label = monthLabel(pid), mon = label.split(" ")[0];
    const inProgress = pid > snapshotMonth();
    const seg = `<div class="seg" role="group" aria-label="Month">${periods().map((p) => `<button data-period="${p}" aria-pressed="${p === pid}">${monthLabel(p).slice(0, 3)}</button>`).join("")}</div>`;
    if (inProgress) {
      const owed = fixtureSplit();
      return `<h1>${mon} so far</h1><p class="sub">The month is still open, so nothing here is estimated.</p>${seg}
        <div class="card" style="margin-top:14px"><div class="empty"><div class="big-num">No posted totals yet</div><p class="small">Lana charts ${mon} once its transactions post. Pick September to see a complete month.</p></div></div>
        <h2>Pending, not counted</h2>
        <div class="card list"><button class="item" data-tab="split"><div class="grow"><div class="t">Dinner reimbursements owed to you</div><div class="s">${esc(DS.receipts[0].merchant)} · Oct 11 · tracked in Split</div></div><div class="a num">${owed.ok ? fmt(owed.r.outstanding_cents, { cents: true }) : "—"}</div><span class="chev">›</span></button></div>
        <p class="note">The October receipt never changes September’s numbers.</p>`;
    }
    const stays = f.to_savings_cents + f.to_investments_cents + f.retained_cash_cents;
    const flowOk = f.net_income_cents === f.expenses_cents + f.to_savings_cents + f.to_investments_cents + f.retained_cash_cents && sum(v.categories, (c) => c.total_cents) === f.expenses_cents;
    const biggest = v.categories[0];
    const answer = `In ${mon} you brought in <b>${fmt(f.net_income_cents)}</b> and spent <b>${fmt(f.expenses_cents)}</b>. ${esc(biggest.category)} was the biggest cost at ${fmt(biggest.total_cents)}. You moved ${fmt(f.to_savings_cents)} to savings and ${fmt(f.to_investments_cents)} to investing, and ${fmt(f.retained_cash_cents)} stayed in checking.`;
    const head = `${bubbles(`Where did my money go in ${mon}?`, answer)}
      <h1>${fmt(stays)} stayed with you</h1>
      <p class="sub">${fmt(f.net_income_cents)} came in during ${label}. ${fmt(f.expenses_cents)} went to expenses.</p>
      ${seg}
      <div class="seg" role="group" aria-label="View" style="margin-top:8px"><button data-mview="flow" aria-pressed="${S.money.view === "flow"}">Money in &amp; out</button><button data-mview="bal" aria-pressed="${S.money.view === "bal"}">Where it sits</button></div>`;
    if (!flowOk) return head + `<div class="card" style="margin-top:12px"><span class="tag bad">Doesn’t reconcile</span><p>These numbers don’t add up, so Lana won’t chart them.</p></div>`;

    if (S.money.view === "bal") {
      const snap = mv(snapshotMonth()), when = dateLabel(DS.as_of);
      const acctRow = (a) => `<button class="item" data-acct="${a.account_id}"><div class="grow"><div class="t">${esc(KIND[a.kind] || a.kind)}</div><div class="s">${esc(a.institution)}${a.opening_balance_cents != null ? ` · ${fmt(a.opening_balance_cents)} on Sep 1` : ""}</div></div><div class="a num">${fmt(a.balance_cents)}</div><span class="chev">›</span></button>`;
      return head + `
        <div class="card" style="margin-top:12px">
          <div class="muted small">Net worth on ${when}</div>
          <div class="hero-amt num" style="margin-top:6px">${fmt(snap.net_worth_cents)}</div>
          <div class="hero-line">${fmt(snap.assets_cents)} in assets minus ${fmt(snap.liabilities_cents)} owed</div>
          <div class="bar" style="height:10px;margin-top:14px"><span style="width:100%;background:var(--accent)"></span></div>
          <div class="bar" style="height:10px;margin-top:6px"><span style="width:0;background:var(--goes)" data-w="${(snap.liabilities_cents / snap.assets_cents) * 100}"></span></div>
          <div class="legend"><span><i class="dot" style="background:var(--accent)"></i>Assets</span><span><i class="dot" style="background:var(--goes)"></i>Liabilities</span></div>
        </div>
        <h2>What you own</h2><div class="card list">${snap.accounts.filter((a) => a.asset_or_liability === "asset").map(acctRow).join("")}</div>
        <h2>What you owe</h2><div class="card list">${snap.accounts.filter((a) => a.asset_or_liability === "liability").map(acctRow).join("")}</div>
        <p class="note">Balances are a snapshot at the end of ${when}${pid !== snapshotMonth() ? ", the latest available" : ""}. Monthly income and spending are under Money in &amp; out.</p>`;
    }
    const max = Math.max(...v.categories.map((c) => c.total_cents));
    const chk = v.accounts.find((a) => a.kind === "checking");
    const keptSub = pid === snapshotMonth() && chk && chk.opening_balance_cents != null ? `Checking grew from ${fmt(chk.opening_balance_cents)} to ${fmt(chk.balance_cents)}` : "Left in checking this month";
    return head + `
      <div class="card" style="margin-top:12px">${flowSVG(f)}
        <div class="legend"><span><i class="dot" style="background:var(--goes)"></i>Went out</span><span><i class="dot" style="background:var(--accent)"></i>Stayed with you</span></div></div>
      <div class="explain"><div class="k">✓ Adds up</div><p class="num">${fmt(f.net_income_cents)} = ${fmt(f.expenses_cents)} spent + ${fmt(f.to_savings_cents)} saved + ${fmt(f.to_investments_cents)} invested + ${fmt(f.retained_cash_cents)} kept.</p></div>
      <h2>Spending by category</h2>
      <div class="card list">${v.categories.map((c) => `<button class="item" data-cat="${esc(c.category)}"><div class="grow"><div class="row"><span class="t">${esc(c.category)}</span><span class="a num">${fmt(c.total_cents)}</span></div><div class="bar"><span style="width:0" data-w="${(c.total_cents / max) * 100}"></span></div></div><span class="chev">›</span></button>`).join("")}
        <div class="kv total"><span>Total spending</span><span class="num">${fmt(f.expenses_cents)}</span></div></div>
      <h2>Set aside, not spent</h2>
      <div class="card list">
        <button class="item" data-xfer="savings"><i class="dot" style="background:var(--accent)"></i><div class="grow"><div class="t">To savings</div><div class="s">Transfer, not spending</div></div><div class="a num">${fmt(f.to_savings_cents)}</div><span class="chev">›</span></button>
        <button class="item" data-xfer="brokerage"><i class="dot" style="background:var(--accent-2)"></i><div class="grow"><div class="t">To investing</div><div class="s">Transfer, not spending</div></div><div class="a num">${fmt(f.to_investments_cents)}</div><span class="chev">›</span></button>
        <div class="item"><i class="dot" style="background:var(--accent-3)"></i><div class="grow"><div class="t">Kept in checking</div><div class="s">${keptSub}</div></div><div class="a num">${fmt(f.retained_cash_cents)}</div></div>
      </div>
      ${v.pending_cents ? `<p class="note">${fmt(v.pending_cents, { cents: true })} pending, not included above.</p>` : ""}`;
  }
  function txList(txs) {
    return `<div class="list">${txs.map((t) => `<div class="item"><div class="grow"><div class="t">${esc(t.merchant)}</div><div class="s">${dateLabel(t.posted_at)}</div></div><div class="a num">${fmt(Math.abs(t.signed_amount_cents), { cents: true })}</div></div>`).join("")}</div>`;
  }
  function catSheet(name) {
    const v = mv(S.money.period), c = v.categories.find((x) => x.category === name), by = txById();
    const txs = c.transaction_ids.map((id) => by[id]);
    sheet(`<h3>${esc(name)}</h3><p class="muted small" style="margin:4px 0 10px">${monthLabel(S.money.period)} · ${txs.length} transaction${txs.length === 1 ? "" : "s"}</p>
      ${txList(txs)}<div class="kv total"><span>Total</span><span class="num">${fmt(c.total_cents, { cents: true })}</span></div>
      <button class="btn ghost" data-close style="margin-top:12px">Done</button>`);
  }
  function xferSheet(kind) {
    const p = S.money.period, ids = new Set(DS.accounts.filter((a) => a.kind === kind).map((a) => a.account_id));
    const pairs = new Set(DS.transactions.filter((t) => ids.has(t.account_id) && t.transfer_pair_id).map((t) => t.transfer_pair_id));
    const txs = DS.transactions.filter((t) => pairs.has(t.transfer_pair_id) && t.signed_amount_cents < 0 && E.monthKey(t.posted_at, DS.user.timezone) === p);
    sheet(`<h3>${kind === "savings" ? "To savings" : "To investing"}</h3><p class="muted small" style="margin:4px 0 10px">${monthLabel(p)}</p>
      ${txList(txs)}<p class="note">Moved between your own accounts, so it isn’t counted as spending.</p>
      <button class="btn ghost" data-close style="margin-top:12px">Done</button>`);
  }
  function acctSheet(id) {
    const a = mv(snapshotMonth()).accounts.find((x) => x.account_id === id);
    const d = a.opening_balance_cents != null ? a.balance_cents - a.opening_balance_cents : null;
    sheet(`<h3>${esc(KIND[a.kind] || a.kind)}</h3><p class="muted small" style="margin:4px 0 12px">${a.asset_or_liability === "asset" ? "Asset" : "Liability, amount owed"} · balance snapshot</p>
      <div class="big-num num">${fmt(a.balance_cents)}</div>
      ${a.opening_balance_cents != null ? `<div class="kv"><span class="muted">Sep 1 balance</span><span class="num">${fmt(a.opening_balance_cents)}</span></div>
      <div class="kv"><span class="muted">Change in September</span><span class="num">${d === 0 ? "No change" : fmt(d, { plus: true })}</span></div>` : ""}
      <div class="kv"><span class="muted">Source</span><span>${esc(a.institution)} · demo data</span></div>
      <div class="kv"><span class="muted">Last refreshed</span><span>${dateLabel(a.as_of)}, 11:59 PM</span></div>
      ${a.reconciled ? '<div class="sim" style="color:var(--accent)">✓ Opening balance plus September activity matches this balance</div>' : ""}
      <button class="btn ghost" data-close style="margin-top:12px">Done</button>`);
  }

  // ======================= JOURNEY 2: BUDGET =======================
  // Bounded preview adapter: re-totals category targets from the per-suggestion savings in
  // preview-data.js. Current totals and income come from the money engine (September).
  const swapSavings = (s) => s.cur - s.next;
  function swapsInPlay() {
    const b = P.budget;
    if (S.budget.memoryOn) return b.swaps;
    const w = b.without_memory;
    return b.swaps.map((s) => (s.id === w.replaces ? { ...s, group: w.group, to: w.to, next: w.next, reason: w.reason, memory: false } : s));
  }
  function budgetPlan() {
    const base = mv(P.budget.base_period), b = P.budget;
    const current = Object.fromEntries(base.categories.map((c) => [c.category, c.total_cents]));
    const items = [...swapsInPlay().map((s) => ({ ...s, savings: swapSavings(s) })), ...b.habits];
    const target = { ...current };
    items.forEach((x) => { if (S.budget.accepted[x.id]) target[x.category] -= x.savings; });
    const curTotal = sum(Object.values(current)), tgtTotal = sum(Object.values(target)), reduction = curTotal - tgtTotal;
    const f = base.flow;
    return { current, target, curTotal, tgtTotal, reduction, f, retainedNext: f.retained_cash_cents + reduction };
  }
  const planSig = () => JSON.stringify([S.budget.accepted, S.budget.memoryOn]);

  function viewBudget() {
    const b = P.budget, PL = budgetPlan(), goal = b.extra_savings_cents;
    const card = (s, habit) => {
      const on = !!S.budget.accepted[s.id], sv = habit ? s.savings : swapSavings(s);
      return `<div class="swap ${on ? "" : "off"}">
        <div class="row"><h3 style="font-size:15.5px">${esc(s.title)}</h3><span class="num" style="color:var(--accent);font-weight:700">${fmt(sv)}/mo</span></div>
        ${habit ? `<div class="fromto">${esc(s.category)} · habit change</div>` : `<div class="fromto"><s>${esc(s.from)}</s> <b class="num">${fmt(s.cur)}</b><br>→ ${esc(s.to)} <b class="num">${fmt(s.next)}</b></div>`}
        <div class="small" style="margin-bottom:10px">${s.memory ? '<span class="tag acc">From your history</span> ' : ""}${esc(s.reason)}</div>
        <div class="toggle" role="group" aria-label="${esc(s.title)}"><button class="yes" data-acc="${s.id}" aria-pressed="${on}">Keep</button><button class="no" data-rej="${s.id}" aria-pressed="${!on}">Skip</button></div></div>`;
    };
    const changed = S.budget.adopted && S.budget.adopted.sig !== planSig();
    const swapTotal = sum(swapsInPlay().filter((s) => S.budget.accepted[s.id]), swapSavings);
    const habitTotal = sum(b.habits.filter((s) => S.budget.accepted[s.id]), (s) => s.savings);
    const rows = Object.keys(PL.current);
    const line = "padding-top:8px;border-top:1px solid var(--line)";
    return `${bubbles("Help me save $150 next month without changing my rent.", `Here’s a plan that keeps rent at ${fmt(PL.current.Rent)} and frees up <b>${fmt(goal)}</b> a month: four swaps worth $100 and three small habit changes worth $50.`)}
      <h1>${fmt(PL.reduction)} a month, projected</h1>
      <p class="sub">${PL.reduction >= goal ? "Meets your $150 goal." : `${fmt(goal - PL.reduction)} short of your $150 goal.`} A plan for ${b.period}. Nothing is saved until you spend less.</p>
      ${S.budget.adopted ? `<div class="explain"><div class="k">✓ ${changed ? "Edited since adopting" : "Adopted"}</div><p>${changed ? "Review and adopt again to update your budget." : `Your ${b.period} budget is updated. Balances and purchases are unchanged.`}</p></div>` : ""}
      <div class="card">
        <div class="cmp num"><span class="h">Category</span><span class="h" style="text-align:right">Sep</span><span class="h" style="text-align:right">Plan</span>
        ${rows.map((k) => `<span>${esc(k.replace(" and subscriptions", " & subs"))}</span><span style="text-align:right" class="muted">${fmt(PL.current[k])}</span><span style="text-align:right" class="${PL.target[k] < PL.current[k] ? "d" : ""}">${fmt(PL.target[k])}</span>`).join("")}
        <span style="font-weight:700;${line}">Total</span><span style="text-align:right;${line}" class="muted">${fmt(PL.curTotal)}</span><span style="text-align:right;font-weight:700;${line}">${fmt(PL.tgtTotal)}</span></div>
        <div class="kv" style="margin-top:12px"><span class="muted">To savings &amp; investing</span><span class="num">${fmt(PL.f.to_savings_cents + PL.f.to_investments_cents)} · unchanged</span></div>
        <div class="kv"><span class="muted">Kept in checking</span><span class="num">${fmt(PL.f.retained_cash_cents)} → <b style="color:var(--accent)">${fmt(PL.retainedNext)}</b></span></div>
      </div>
      <h2>Your rules</h2>
      <div class="card flat"><div class="chips">${b.constraints.filter((c) => S.budget.memoryOn || c.id !== "c_instant").map((c) => `<span class="chip rule" title="${esc(c.source)}">✓ ${esc(c.text)}</span>`).join("")}</div></div>
      <h2>Swaps · ${fmt(swapTotal)}</h2>${swapsInPlay().map((s) => card(s, false)).join("")}
      <p class="note">Prices are illustrative demo assumptions, not live quotes.</p>
      <h2>Habits · ${fmt(habitTotal)}</h2>${b.habits.map((s) => card(s, true)).join("")}
      <h2>Left out on purpose</h2>
      <div class="card flat list">${b.excluded.filter((x) => S.budget.memoryOn || !x.memory).map((x) => `<div class="item"><div class="grow"><div class="t">${esc(x.title)}</div><div class="s">${esc(x.why)}</div></div><span class="num muted">${fmt(x.savings)}/mo</span></div>`).join("")}
        <button class="item" data-why><div class="grow"><div class="t" style="color:var(--accent)">Why these suggestions?</div></div><span class="chev">›</span></button></div>
      <div style="margin-top:16px"><button class="btn accent" data-adopt ${S.budget.adopted && !changed ? "disabled" : ""}>${S.budget.adopted && !changed ? "Plan adopted" : "Review & adopt plan"}</button></div>`;
  }
  function whySheet() {
    const m = P.budget.memory;
    sheet(`<h3>Why these suggestions?</h3>
      <p class="small" style="margin:8px 0 12px">Lana checks your past swap decisions before suggesting alternatives. Your own rules always win.</p>
      <div class="kv"><span class="muted">History checked</span><span>${esc(m.queried_at)}</span></div>
      <div class="kv"><span class="muted">Evidence</span><span>You rejected instant coffee ${m.evidence_count} times</span></div>
      <div class="kv"><span class="muted">Effect</span><span>${S.budget.memoryOn ? "Instant coffee left out" : "Not applied"}</span></div>
      <div class="card flat" style="margin-top:14px"><div class="row"><div><div style="font-weight:600">Use decision history</div><div class="small muted">Turn off to see the plan without it</div></div>
      <div class="toggle"><button class="yes" data-mem="1" aria-pressed="${S.budget.memoryOn}">On</button><button class="no" data-mem="0" aria-pressed="${!S.budget.memoryOn}">Off</button></div></div>
      <div class="sim">◆ Demo adapter with synthetic history. Not a verified ${esc(m.provider)} connection.</div></div>
      <button class="btn ghost" data-close style="margin-top:12px">Done</button>`);
  }
  function adoptSheet() {
    const PL = budgetPlan(), b = P.budget, changes = Object.keys(PL.current).filter((k) => PL.target[k] !== PL.current[k]);
    sheet(`<h3>Adopt budget for ${b.period}?</h3>
      <div class="list" style="margin:10px 0">${changes.map((k) => `<div class="item"><div class="grow t">${esc(k)}</div><span class="num muted">${fmt(PL.current[k])}</span><span class="num">→ <b>${fmt(PL.target[k])}</b></span></div>`).join("")}</div>
      <div class="kv total"><span>Projected monthly savings</span><span class="num" style="color:var(--accent)">${fmt(PL.reduction)}</span></div>
      <p class="small muted">This updates your budget only. It doesn’t move money, change account balances, buy products or switch your phone plan.</p>
      <div class="btns" style="margin-top:12px"><button class="btn ghost" data-close>Not now</button><button class="btn accent" data-adopt-confirm>Adopt plan</button></div>`);
  }

  // ======================= JOURNEY 3: SPLIT =======================
  const receipt = () => DS.receipts[0];
  const payerId = () => DS.split_example.payer_id;
  function people() {
    const ids = new Set([payerId(), ...Object.values(DS.split_example.assignments).flat()]);
    const order = DS.contacts.filter((c) => ids.has(c.contact_id));
    return [...order.filter((c) => c.contact_id === payerId()), ...order.filter((c) => c.contact_id !== payerId())];
  }
  const person = (id) => DS.contacts.find((c) => c.contact_id === id);
  const av = (id) => `<span class="avatar a${people().findIndex((p) => p.contact_id === id) + 1}">${esc(person(id).reviewed_name[0])}</span>`;
  const reviewedReceipt = () => ({ ...receipt(), tip_cents: S.split.tip });
  function assignments() {
    const all = people().map((p) => p.contact_id);
    return Object.fromEntries(receipt().items.map((i) => [i.item_id, S.split.owners[i.item_id] === "shared" ? all : [S.split.owners[i.item_id]]]));
  }
  function splitResult() {
    try { return { ok: true, r: E.prepareSplit({ receipt: reviewedReceipt(), assignments: assignments(), payerId: payerId(), contacts: DS.contacts, datasetVersion: DS.dataset_version, dataMode: DS.data_mode }) }; }
    catch (e) { return { ok: false, e }; }
  }
  // The fixture receipt is the reviewed truth; used where no review is in progress (Money tab).
  function fixtureSplit() {
    const ex = DS.split_example;
    try { return { ok: true, r: E.prepareSplit({ receipt: receipt(), assignments: ex.assignments, payerId: ex.payer_id, contacts: DS.contacts, datasetVersion: DS.dataset_version, dataMode: DS.data_mode }) }; }
    catch (e) { return { ok: false, e }; }
  }
  const reqState = (id) => S.split.req[id] || "draft";
  const STEPS = ["Inputs", "Check", "Assign", "Shares", "Requests", "Follow-ups"];
  const REQ_STATES = [["draft", "Draft"], ["ready_for_review", "Ready for review"], ["handed_off", "Handed off"], ["user_reported_requested", "You sent it"], ["paid_reported", "Paid (you said)"]];

  function viewSplit() {
    const rc = receipt(), st = S.split, merchant = rc.merchant, dateStr = dateLabel(rc.date + "T12:00:00-07:00");
    const stepper = `<div class="stepper">${STEPS.map((_, i) => `<span class="${i <= st.step ? "on" : ""}"></span>`).join("")}</div>`;
    const nav = (next, label, dis) => `<div class="btns" style="margin-top:14px">${st.step > 0 ? '<button class="btn ghost" data-back style="width:auto;padding:0 18px">Back</button>' : ""}<button class="btn accent" data-next="${next}" ${dis ? "disabled" : ""}>${label}</button></div>`;
    const head = (t, s) => `${stepper}<p class="muted small" style="margin:0 4px">Step ${st.step + 1} of ${STEPS.length} · ${STEPS[st.step]}</p><h1>${t}</h1>${s ? `<p class="sub">${s}</p>` : ""}`;

    if (st.step === 0) {
      const wave = Array.from({ length: 34 }, (_, i) => `<i style="height:${6 + Math.round(Math.abs(Math.sin(i * 1.7) * 18 + Math.cos(i * 0.6) * 4))}px"></i>`).join("");
      const both = st.receipt && st.voice;
      return head("Split dinner", "Send a receipt and a voice note to Lana in Messages, or add them here.") + `
        <div class="card"><div class="row"><h3>Receipt</h3>${st.receipt ? '<span class="tag acc">Received</span>' : '<span class="tag">Waiting</span>'}</div>
          ${st.upload ? `<img src="${st.upload}" alt="Your uploaded receipt" style="width:100%;max-height:160px;object-fit:cover;border-radius:12px;margin-top:10px">` : ""}
          ${st.receipt ? `<p class="small muted" style="margin:8px 0 0">${st.upload ? "Your photo is shown. This preview reads the sample receipt; on iPhone the photo is read on-device." : `${esc(merchant)} · ${dateStr}`}</p>` : ""}
          <div class="btns" style="margin-top:12px"><button class="btn small ${st.receipt ? "ghost" : ""}" data-sample-receipt>Use sample receipt</button>
          <label class="btn small ghost" style="cursor:pointer">Upload photo<input type="file" accept="image/*" data-upload hidden></label></div></div>
        <div class="card"><div class="row"><h3>Voice note</h3>${st.voice ? '<span class="tag acc">Transcribed</span>' : '<span class="tag">Waiting</span>'}</div>
          ${st.voice ? `<div class="row" style="margin-top:10px;gap:10px"><span class="avatar" style="background:var(--accent);color:#fff">▶</span><div class="wave" aria-hidden="true">${wave}</div><span class="small muted num">0:07</span></div>
          <p style="margin:10px 0 0;font-size:15px">“${esc(P.split.transcript)}”</p><div class="sim">◆ Sample transcript. On iPhone, speech is transcribed on-device.</div>` : ""}
          <div style="margin-top:12px"><button class="btn small ${st.voice ? "ghost" : ""}" data-sample-voice>Use sample voice note</button></div></div>
        <div class="card flat"><div class="row"><span class="small">Messages delivery</span><span class="pill ${both ? "ok" : "muted"}">${both ? "Completed · 2 of 2" : st.receipt || st.voice ? "Pending · 1 of 2" : "Waiting"}</span></div>
          <div class="sim">◆ Simulated delivery states. The messaging line isn’t connected in this preview.</div></div>
        ${nav(1, "Read receipt", !both)}`;
    }
    if (st.step === 1) {
      const ln = (n, c, cls = "") => `<div class="row ${cls}"><span>${esc(n)}</span><span>${fmt(c, { cents: true })}</span></div>`;
      const sr = splitResult(), mismatch = !sr.ok && sr.e.code === "RECEIPT_MISMATCH";
      const diff = rc.total_cents - (rc.subtotal_cents + rc.tax_cents + st.tip);
      return head("Check what Lana read", mismatch ? "One field looks off. Fix it before anything is sent." : "Everything adds up to the receipt total.") + `
        <div class="receipt" aria-label="Receipt image"><div class="c"><b>${esc(merchant.toUpperCase())}</b><br>${esc(rc.date)}</div><br>
          ${rc.items.map((i) => ln(i.description, i.extended_price_cents)).join("")}<br>${ln("Subtotal", rc.subtotal_cents)}${ln("Tax", rc.tax_cents)}${ln("Tip", rc.tip_cents, st.tipFixed ? "" : "hl")}<b>${ln("TOTAL", rc.total_cents)}</b></div>
        <div class="card" style="margin-top:14px">
          <div class="small muted" style="margin-bottom:4px">What Lana read</div>
          ${rc.items.map((i) => `<div class="field"><span>${esc(i.description)}</span><span class="num">${fmt(i.extended_price_cents, { cents: true })}</span></div>`).join("")}
          <div class="field"><span>Tax</span><span class="num">${fmt(rc.tax_cents, { cents: true })}</span></div>
          <div class="field ${st.tipFixed ? "" : "flag"}"><span>Tip ${st.tipFixed ? '<span class="tag acc">Corrected</span>' : `<span class="tag warn">Unsure · ${Math.round(P.split.ocr_misread.confidence * 100)}%</span>`}</span><input inputmode="decimal" aria-label="Tip amount" data-tip value="${(st.tip / 100).toFixed(2)}"></div>
          <div class="kv total"><span>Receipt total</span><span class="num">${fmt(rc.total_cents, { cents: true })}</span></div>
          ${mismatch ? `<div class="sim" style="color:var(--bad)">✕ Off by ${fmt(Math.abs(diff), { cents: true })}. Requests stay blocked until this matches.</div>` : '<div class="sim" style="color:var(--accent)">✓ Items, tax and tip match the total</div>'}
          <div class="sim">◆ The low-confidence tip is staged so you can see the correction step.</div></div>
        <div class="card flat"><div class="small muted">Instruction</div><p style="margin:4px 0 0">“${esc(P.split.transcript)}”</p></div>
        ${nav(2, "Assign items", mismatch)}`;
    }
    if (st.step === 2) {
      const ppl = people(), opts = [...ppl.map((p) => [p.contact_id, p.reviewed_name]), ["shared", "Shared"]];
      return head("Who had what", "Filled in from your voice note. Tap to change.") + `
        <h2>People</h2>
        <div class="card list">${ppl.map((p) => `<div class="item">${av(p.contact_id)}<div class="grow"><div class="t">${esc(p.reviewed_name)}${p.is_self ? " (you)" : ""}</div><div class="s">${p.contact_id === payerId() ? "Paid the bill" : `${esc(p.venmo_handle)} · ${phoneFmt(p.phone)}`}</div></div>${p.is_self ? "" : '<span class="tag acc">Reviewed contact</span>'}</div>`).join("")}</div>
        <h2>Items</h2>
        ${rc.items.map((i) => `<div class="card"><div class="row"><span style="font-weight:600">${esc(i.description)}</span><span class="num">${fmt(i.extended_price_cents, { cents: true })}</span></div><div class="chips" style="margin-top:10px">${opts.map(([id, n]) => `<button class="chip" data-own="${i.item_id}|${id}" aria-pressed="${st.owners[i.item_id] === id}">${esc(n)}</button>`).join("")}</div></div>`).join("")}
        ${nav(3, "Calculate shares")}`;
    }
    const sr = splitResult();
    if (!sr.ok) return head("Can’t split yet", "") + `<div class="card"><span class="tag bad">Needs a fix</span><p>${esc(sr.e.message)}</p></div>${nav(st.step, "Continue", true)}`;
    const r = { ...sr.r, requests: people().map((p) => sr.r.requests.find((q) => q.contact_id === p.contact_id)).filter(Boolean) }, byId = Object.fromEntries(r.shares.map((s) => [s.contact_id, s]));
    if (st.step === 3) {
      const ordered = people().map((p) => byId[p.contact_id]), total = sum(r.shares, (s) => s.total_cents), ok = total === rc.total_cents;
      return head(`You’re owed ${fmt(r.outstanding_cents, { cents: true })}`, "The appetizer is split evenly. Tax and tip follow what each person ordered.") + `
        ${ordered.map((x) => `<div class="card"><div class="row">${av(x.contact_id)}<div class="grow" style="margin-left:4px"><div style="font-weight:650">${esc(person(x.contact_id).reviewed_name)}</div><div class="small muted num">${fmt(x.items_cents, { cents: true })} food + ${fmt(x.tax_tip_cents, { cents: true })} tax &amp; tip</div></div><div class="big-num num" style="font-size:24px">${fmt(x.total_cents, { cents: true })}</div></div>${x.contact_id === payerId() ? '<div class="small muted" style="margin-top:6px">Your share. You paid the bill.</div>' : ""}</div>`).join("")}
        <div class="explain"><div class="k">${ok ? "✓ Adds up" : "✕ Mismatch"}</div><p class="num">${ordered.map((x) => fmt(x.total_cents, { cents: true })).join(" + ")} = ${fmt(total, { cents: true })}, the receipt total.</p></div>
        <p class="note">Dated Oct 11, so it isn’t added to September’s spending.</p>
        ${nav(4, "Prepare requests", !ok)}`;
    }
    if (st.step === 4) {
      return head("Payment requests", "Nothing is sent without your review. Opening Venmo isn’t the same as sending a request.") + `
        ${r.requests.map((q) => reqCard(q)).join("")}
        <p class="note">Lana can’t see inside Venmo. “You sent it” and “Paid” are what you tell Lana.</p>
        ${nav(5, "Set up follow-ups")}`;
    }
    return head("Follow-ups", "Lana can remind people who haven’t paid. Each reminder needs your OK.") + `
      <div class="card"><div class="row"><div><div class="small muted">Demo clock</div><div style="font-weight:650">${st.clock ? "Mon, Oct 12 · 10:00 AM" : "Sun, Oct 11 · 8:40 PM"}</div></div>
      <button class="btn small ${st.clock ? "ghost" : ""}" data-clock>${st.clock ? "Back to today" : "Jump to tomorrow"}</button></div>
      <div class="sim">◆ Simulated clock for the demo. Real time and security timeouts are unchanged.</div></div>
      ${r.requests.map((q) => remCard(q)).join("")}
      <div class="btns" style="margin-top:14px"><button class="btn ghost" data-back style="width:auto;padding:0 18px">Back</button><button class="btn ghost" data-restart-split>Start over</button></div>`;
  }
  function stateRow(cur) {
    if (cur === "cancelled") return `<div class="state"><span class="cur">Cancelled</span></div>`;
    const idx = REQ_STATES.findIndex(([k]) => k === cur);
    return `<div class="state">${REQ_STATES.map(([k, l], i) => `<span class="${i < idx ? "done" : i === idx ? "cur" : ""}">${l}</span>`).join("")}</div>`;
  }
  function reqCard(q) {
    const id = q.contact_id, s = reqState(id);
    const act = {
      draft: `<button class="btn small" data-req="${id}|review">Review request</button>`,
      ready_for_review: `<button class="btn small" data-req="${id}|review">Review request</button>`,
      handed_off: `<button class="btn small" data-req="${id}|sent">I sent it in Venmo</button><button class="btn small ghost" data-req="${id}|cancel">Cancel</button>`,
      user_reported_requested: `<button class="btn small accent" data-req="${id}|paid">Mark paid</button><button class="btn small ghost" data-req="${id}|cancel">Cancel</button>`,
      paid_reported: `<span class="tag acc">Paid, as you reported</span>`,
      cancelled: `<button class="btn small ghost" data-req="${id}|reopen">Reopen draft</button>`
    }[s];
    return `<div class="card"><div class="row">${av(id)}<div class="grow" style="margin-left:4px"><div style="font-weight:650">${esc(q.reviewed_name)}</div><div class="small muted">${esc(q.venmo_handle)}</div></div><div class="num" style="font-weight:700;font-size:18px">${fmt(q.amount_cents, { cents: true })}</div></div>
      ${stateRow(s)}<div class="btns" style="margin-top:12px;flex-wrap:wrap">${act}</div></div>`;
  }
  const findReq = (id) => splitResult().r.requests.find((q) => q.contact_id === id);
  function reviewReqSheet(id) {
    const q = findReq(id);
    if (reqState(id) === "draft") S.split.req[id] = "ready_for_review";
    render();
    sheet(`<h3>Request ${fmt(q.amount_cents, { cents: true })} from ${esc(q.reviewed_name)}</h3>
      <div class="kv"><span class="muted">To</span><span>${esc(q.reviewed_name)} · ${esc(q.venmo_handle)}</span></div>
      <div class="kv"><span class="muted">Amount</span><span class="num">${fmt(q.amount_cents, { cents: true })}</span></div>
      <div class="kv" style="gap:16px"><span class="muted">Note</span><span style="text-align:right">${esc(q.note)}</span></div>
      <div class="kv"><span class="muted">How</span><span>Open Venmo with details filled in</span></div>
      <p class="small muted">You finish and send the request yourself in Venmo. Lana won’t know it was sent until you say so.</p>
      <div class="sim">◆ Preview: Venmo won’t open here. The details are copied instead.</div>
      <div class="btns" style="margin-top:14px"><button class="btn ghost" data-close>Not now</button><button class="btn accent" data-handoff="${id}">Approve &amp; open Venmo</button></div>`);
  }
  function remCard(q) {
    const id = q.contact_id, st = S.split, r = st.reminders[id], s = reqState(id), paid = s === "paid_reported", disputed = st.disputed[id];
    const text = `Hey ${q.reviewed_name}, quick reminder: your share of dinner at ${receipt().merchant} was ${fmt(q.amount_cents, { cents: true })}. Thanks!`;
    let status, action = "";
    if (paid || disputed || s === "cancelled") {
      status = `<span class="tag">${r ? "Reminder cancelled" : "No reminder needed"}</span>${paid ? ' <span class="tag acc">Paid (you said)</span>' : ""}${disputed ? ' <span class="tag bad">Disputed</span>' : ""}${s === "cancelled" ? ' <span class="tag">Request cancelled</span>' : ""}`;
    } else if (!r) {
      status = `<span class="tag warn">Unpaid</span>`; action = `<button class="btn small" data-rem="${id}">Approve reminder</button>`;
    } else {
      status = `<span class="tag acc">${st.clock ? "Reminder sent Oct 12, 10:00 AM" : "Reminder set · tomorrow 10:00 AM"}</span>`;
      action = `<button class="btn small accent" data-req="${id}|paid">Mark paid</button>`;
    }
    const canDispute = !paid && !disputed && s !== "cancelled";
    return `<div class="card"><div class="row">${av(id)}<div class="grow" style="margin-left:4px"><div style="font-weight:650">${esc(q.reviewed_name)} owes ${fmt(q.amount_cents, { cents: true })}</div><div style="margin-top:6px">${status}</div></div></div>
      ${r && st.clock && !paid && !disputed && s !== "cancelled" ? `<div class="bubble lana" style="margin-top:10px;max-width:100%">${esc(text)}</div><div class="sim">◆ Simulated send. The messaging line isn’t connected here.</div>` : ""}
      <div class="btns" style="margin-top:12px;flex-wrap:wrap">${action}${canDispute ? `<button class="btn small ghost" data-dispute="${id}">They disputed it</button>` : ""}</div></div>`;
  }
  function remSheet(id) {
    const q = findReq(id), p = person(id);
    sheet(`<h3>Remind ${esc(q.reviewed_name)} tomorrow?</h3>
      <div class="bubble lana" style="margin:12px 0;max-width:100%">Hey ${esc(q.reviewed_name)}, quick reminder: your share of dinner at ${esc(receipt().merchant)} was ${fmt(q.amount_cents, { cents: true })}. Thanks!</div>
      <div class="kv"><span class="muted">To</span><span>${phoneFmt(p.phone)}</span></div>
      <div class="kv"><span class="muted">Channel</span><span>Messages</span></div>
      <div class="kv"><span class="muted">When</span><span>Once, tomorrow 10:00 AM</span></div>
      <p class="small muted">Cancelled automatically if they pay or dispute it.</p>
      <div class="btns" style="margin-top:12px"><button class="btn ghost" data-close>Not now</button><button class="btn accent" data-rem-confirm="${id}">Approve reminder</button></div>`);
  }

  // ======================= VAULT =======================
  let vaultTimer;
  function viewVault() {
    const v = S.vault;
    const privacy = `<h2>Privacy</h2><div class="card flat small">
      <p style="margin:0 0 8px"><b>The model and financial reasoning run on your phone.</b></p>
      <p style="margin:0 0 8px">Messages you send Lana pass through a messaging provider, and connected services receive what they need to work.</p>
      <p style="margin:0">Lana’s model sees connection names and what they’re allowed to do. It never sees passwords, tokens or verification codes.</p></div>`;
    const activity = `<h2>Approvals</h2><div class="card list">${S.log.length ? S.log.map((l) => `<div class="item"><div class="grow"><div style="font-weight:550">${esc(l.text)}</div><div class="s">${esc(l.at)}</div></div><span class="tag ${l.kind === "approved" ? "acc" : ""}">${esc(l.kind)}</span></div>`).join("") : '<div class="empty small">Nothing approved yet.</div>'}</div>`;
    const sim = `<div class="card flat" style="margin-top:12px"><div class="sim" style="margin:0">◆ Simulated vault. Face ID and authenticator checks are not performed in this browser preview. On iPhone this uses the native secure vault.</div></div>`;
    const lockIcon = '<svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><rect x="4" y="10" width="16" height="11" rx="2.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>';
    if (v.stage === "locked" || v.stage === "bio") {
      return `<div class="lock"><div class="ring">${lockIcon}</div><h1 style="margin:0">Vault is locked</h1><p class="sub" style="margin-top:6px">Connections, saved credentials and sensitive settings.</p></div>
        ${v.err ? `<div class="card flat" style="border-color:var(--bad)"><span class="tag bad">Couldn’t unlock</span><p class="small" style="margin:6px 0 0">${esc(v.err)}</p></div>` : ""}
        <button class="btn accent" data-bio ${v.stage === "bio" ? "disabled" : ""}>${v.stage === "bio" ? "Checking Face ID…" : "Unlock with Face ID"}</button>
        <div style="text-align:center;margin-top:6px"><button class="small muted" data-bio-fail style="min-height:44px;text-decoration:underline">Show a failed attempt</button></div>
        ${sim}${privacy}${activity}`;
    }
    if (v.stage === "otp") {
      return `<div class="lock"><div class="ring" style="font-size:30px">✓</div><h1 style="margin:0">One more step</h1><p class="sub" style="margin-top:6px">Face ID passed. Enter the 6-digit code from your authenticator app.</p></div>
        <div class="otp">${Array.from({ length: 6 }, (_, i) => `<input inputmode="numeric" maxlength="1" aria-label="Digit ${i + 1}" data-otp="${i}">`).join("")}</div>
        ${v.err ? `<p class="small" style="color:var(--bad);text-align:center">${esc(v.err)}</p>` : ""}
        <button class="btn accent" data-otp-go>Verify</button><button class="btn ghost" data-lock style="margin-top:8px">Cancel</button>${sim}`;
    }
    const left = Math.max(0, Math.ceil((v.lockAt - Date.now()) / 1000));
    return `<div class="row" style="margin-top:8px"><h1 style="margin:0">Vault</h1><span class="pill ok">Unlocked · <span data-countdown class="num">${left}s</span></span></div>
      <p class="sub" style="margin-top:6px">Locks after 60 seconds, or as soon as you leave the app.</p>
      <div class="card list">${P.vault.map((s) => `<div class="item"><div class="grow"><div class="t">${esc(s.label)}</div><div class="s">${esc(s.scope)}</div><div class="secret" style="margin-top:4px">${v.revealed[s.id] ? esc(s.value) : "•••• •••• ••••"}</div></div><button class="btn small ghost" data-reveal="${s.id}">${v.revealed[s.id] ? "Hide" : "Show"}</button></div>`).join("")}</div>
      <p class="note">All values are synthetic demo credentials.</p>
      <button class="btn" data-lock>Lock now</button>${sim}${privacy}${activity}`;
  }
  function startVaultTimer() {
    clearInterval(vaultTimer);
    vaultTimer = setInterval(() => {
      if (S.vault.stage !== "unlocked") return clearInterval(vaultTimer);
      const left = Math.ceil((S.vault.lockAt - Date.now()) / 1000);
      if (left <= 0) return lockVault("Vault locked after 60 seconds.");
      const el = $("[data-countdown]"); if (el) el.textContent = left + "s";
    }, 500);
  }
  function lockVault(msg) { S.vault = { stage: "locked", revealed: {}, err: "", lockAt: 0 }; clearInterval(vaultTimer); if (S.tab === "vault") render(); if (msg) toast(msg); }
  document.addEventListener("visibilitychange", () => { if (document.hidden && S && S.vault.stage !== "locked") lockVault(); });

  function demoSheet() {
    sheet(`<h3>Demo data</h3><p class="small" style="margin:8px 0">Every account, transaction, price, contact and credential here is synthetic.</p>
      <div class="card flat small"><b>Simulated in this preview</b><ul style="margin:6px 0 0;padding-left:18px;line-height:1.6">
      <li>Messages delivery and reminders</li><li>Venmo handoff (details are copied)</li><li>Past-decision history for swaps</li><li>Face ID and authenticator checks</li><li>Lana’s replies (written from the same numbers)</li><li>Swap prices (illustrative)</li></ul></div>
      <div class="kv"><span class="muted">Dataset</span><span>${esc(DS.dataset_version)} · ${esc(DS.data_mode)}</span></div>
      <div class="btns" style="margin-top:12px"><button class="btn ghost" data-theme-toggle>Light / dark</button><button class="btn" data-reset>Reset demo</button></div>`);
  }

  // ---------- events ----------
  document.addEventListener("input", (e) => {
    const t = e.target;
    if (t.matches("[data-tip]")) {
      const v = Math.round(parseFloat(t.value.replace(/[^0-9.]/g, "")) * 100);
      if (!isNaN(v)) { S.split.tip = v; S.split.tipFixed = v === receipt().tip_cents; const pos = t.selectionStart; render(); const n = $("[data-tip]"); if (n) { n.focus(); try { n.setSelectionRange(pos, pos); } catch (_) {} } }
    }
    if (t.matches("[data-otp]")) { t.value = t.value.replace(/\D/g, "").slice(0, 1); if (t.value) { const n = $(`[data-otp="${+t.dataset.otp + 1}"]`); if (n) n.focus(); } }
  });
  document.addEventListener("change", (e) => {
    const t = e.target;
    if (t.matches("[data-upload]") && t.files[0]) { const r = new FileReader(); r.onload = () => { S.split.upload = r.result; S.split.receipt = true; render(); }; r.readAsDataURL(t.files[0]); }
  });
  document.addEventListener("click", (e) => {
    const t = e.target.closest("button,[data-close]"); if (!t || !S) return;
    const d = t.dataset;
    if (d.tab) { closeSheet(); return go(d.tab); }
    if (t.id === "demoPill") return demoSheet();
    if ("close" in d) return closeSheet();
    if ("reset" in d) { closeSheet(); clearInterval(vaultTimer); S = initialState(); toast("Demo reset"); top(); return render(); }
    if ("themeToggle" in d) { const r = document.documentElement; const dark = r.dataset.theme ? r.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches; r.dataset.theme = dark ? "light" : "dark"; return; }
    if (d.period) { S.money.period = d.period; return render(); }
    if (d.mview) { S.money.view = d.mview; return render(); }
    if (d.cat) return catSheet(d.cat);
    if (d.xfer) return xferSheet(d.xfer);
    if (d.acct) return acctSheet(d.acct);
    if (d.acc) { S.budget.accepted[d.acc] = true; return render(); }
    if (d.rej) { S.budget.accepted[d.rej] = false; return render(); }
    if ("why" in d) return whySheet();
    if (d.mem) { S.budget.memoryOn = d.mem === "1"; render(); return whySheet(); }
    if ("adopt" in d) return adoptSheet();
    if ("adoptConfirm" in d) {
      if (S.budget.busy) return; S.budget.busy = true; t.disabled = true; t.textContent = "Adopting…";
      setTimeout(() => { S.budget.busy = false; S.budget.adopted = { sig: planSig() }; logAction(`Budget for ${P.budget.period} · ${fmt(budgetPlan().reduction)}/mo projected`); closeSheet(); render(); toast("Budget adopted. Balances unchanged."); }, 600);
      return;
    }
    if ("sampleReceipt" in d) { S.split.receipt = true; S.split.upload = null; return render(); }
    if ("sampleVoice" in d) { S.split.voice = true; return render(); }
    if (d.next) { S.split.step = +d.next; top(); return render(); }
    if ("back" in d) { S.split.step = Math.max(0, S.split.step - 1); top(); return render(); }
    if (d.own) { const [i, o] = d.own.split("|"); S.split.owners[i] = o; return render(); }
    if (d.req) {
      const [id, a] = d.req.split("|"), r = S.split.req, cur = reqState(id), name = person(id).reviewed_name;
      if (a === "review") return reviewReqSheet(id);
      if (a === "sent" && cur === "handed_off") { r[id] = "user_reported_requested"; logAction(`${name}: you reported the request as sent`, "reported"); }
      if (a === "paid" && cur !== "paid_reported") { r[id] = "paid_reported"; logAction(`${name} paid, as you reported`, "reported"); if (S.split.reminders[id]) logAction(`Reminder to ${name} cancelled (paid)`, "cancelled"); }
      if (a === "cancel") { r[id] = "cancelled"; if (S.split.reminders[id]) logAction(`Reminder to ${name} cancelled`, "cancelled"); }
      if (a === "reopen") r[id] = "draft";
      return render();
    }
    if (d.handoff) {
      const id = d.handoff; if (reqState(id) === "handed_off") return closeSheet(); // duplicate tap guard
      const q = findReq(id);
      try { navigator.clipboard && navigator.clipboard.writeText(`${q.venmo_handle} ${(q.amount_cents / 100).toFixed(2)} ${q.note}`).catch(() => {}); } catch (_) {}
      S.split.req[id] = "handed_off"; logAction(`Request for ${q.reviewed_name} · ${fmt(q.amount_cents, { cents: true })} handed off to Venmo`);
      closeSheet(); render(); toast("Details copied. Finish the request in Venmo."); return;
    }
    if (d.rem) return remSheet(d.rem);
    if (d.remConfirm) { const id = d.remConfirm; if (!S.split.reminders[id]) { S.split.reminders[id] = true; logAction(`Reminder to ${person(id).reviewed_name} for tomorrow 10:00 AM`); } closeSheet(); return render(); }
    if (d.dispute) { const id = d.dispute; S.split.disputed[id] = true; if (S.split.reminders[id]) logAction(`Reminder to ${person(id).reviewed_name} cancelled (disputed)`, "cancelled"); return render(); }
    if ("clock" in d) { S.split.clock = S.split.clock ? 0 : 1; return render(); }
    if ("restartSplit" in d) { S.split = initialState().split; top(); return render(); }
    if ("bio" in d) { S.vault.stage = "bio"; S.vault.err = ""; render(); setTimeout(() => { if (S.vault.stage === "bio") { S.vault.stage = "otp"; render(); const f = $('[data-otp="0"]'); if (f) f.focus(); } }, 900); return; }
    if ("bioFail" in d) { S.vault.stage = "locked"; S.vault.err = "Unlock the device and complete authentication to access the credential."; return render(); }
    if ("otpGo" in d) {
      const code = [...document.querySelectorAll("[data-otp]")].map((i) => i.value).join("");
      if (code.length < 6) { S.vault.err = "Enter all 6 digits."; return render(); }
      S.vault = { stage: "unlocked", revealed: {}, err: "", lockAt: Date.now() + 60000 }; render(); startVaultTimer(); return;
    }
    if ("lock" in d) return lockVault();
    if (d.reveal) { S.vault.revealed[d.reveal] = !S.vault.revealed[d.reveal]; S.vault.lockAt = Date.now() + 60000; return render(); }
  });

  // ---------- boot ----------
  async function boot() {
    main.innerHTML = '<div class="empty" style="padding-top:120px">Loading your demo data…</div>';
    const urls = window.LANA_FIXTURE_URLS || ["fixtures/seed-v1.json", "../../fixtures/seed-v1.json"];
    for (const u of urls) {
      try { const r = await fetch(u, { cache: "no-store" }); if (r.ok) { DS = await r.json(); break; } } catch (_) {}
    }
    if (!DS) { main.innerHTML = '<div class="card" style="margin-top:40px"><span class="tag bad">Couldn’t load demo data</span><p class="small">Serve the repo root and open /preview/web/. See preview/README.md.</p></div>'; return; }
    S = initialState(); render();
  }
  boot();
})();
