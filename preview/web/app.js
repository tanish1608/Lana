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
      tab: "home",
      money: { period: "2026-09", view: "flow" },
      budget: { accepted: {}, exec: {}, history: [], cat: null, memoryOn: true, adopted: null, busy: false },
      split: {
        step: 0, receipt: false, voice: false, upload: null,
        tip: P.split.ocr_misread.read, tipFixed: false,
        owners: Object.fromEntries(Object.entries(ex.assignments).map(([item, who]) => [item, who.length > 1 ? "shared" : who[0]])),
        req: {}, reminders: {}, clock: 0, disputed: {}
      },
      rcpt: { open: null, done: {}, upload: null },
      vault: { stage: "locked", revealed: {}, err: "", lockAt: 0 },
      chat: { open: false, typing: false, msgs: [{ from: "lana", text: "Hi Ashwin. Ask me about your money, your plan or who owes you." }] },
      log: []
    };
  }
  function logAction(text, kind = "approved") { S.log.unshift({ text, kind, at: S.split.clock ? "Oct 12 (demo clock)" : "Oct 11" }); }

  // ---------- shell ----------
  const ICONS = {
    home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 10.5 12 4l8.5 6.5V20a1 1 0 0 1-1 1h-5v-6h-5v6h-5a1 1 0 0 1-1-1z"/></svg>',
    money: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 19V9M10 19V5M16 19v-7M22 19H2"/></svg>',
    budget: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 3.5V12l6 4.5"/></svg>',
    split: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h12v18l-3-2-3 2-3-2-3 2z"/><path d="M9 8h6M9 12h6"/></svg>',
    vault: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="4" y="10" width="16" height="11" rx="2.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>'
  };
  ICONS.vault = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="6" width="18" height="13" rx="3"/><path d="M3 10.5h18M7 15h3"/><path d="M6.5 6 8 3.5h8L17.5 6"/></svg>';
  const SPARK = '<svg viewBox="0 0 24 24" width="26" height="26" fill="currentColor"><path d="M12 2.5c.5 4.6 2.9 7 7.5 7.5-4.6.5-7 2.9-7.5 7.5-.5-4.6-2.9-7-7.5-7.5 4.6-.5 7-2.9 7.5-7.5z"/><path d="M19 15.5c.2 1.8 1.1 2.7 2.9 2.9-1.8.2-2.7 1.1-2.9 2.9-.2-1.8-1.1-2.7-2.9-2.9 1.8-.2 2.7-1.1 2.9-2.9z" opacity=".7"/></svg>';
  // Tab id stays "vault" for continuity with the native screens; the screen is now Accounts.
  const TABS = [["home", "Home"], ["budget", "Budget"], ["split", "Receipts"], ["vault", "Accounts"]];
  const navTab = () => (S.tab === "money" ? "home" : S.tab);
  function renderNav() {
    const b = ([id, l]) => `<button class="dock-btn" data-tab="${id}" aria-label="${l}" ${navTab() === id ? 'aria-current="page"' : ""}>${ICONS[id]}<span>${l}</span></button>`;
    $("#nav").innerHTML = `<div class="dock">${TABS.slice(0, 2).map(b).join("")}
      <button class="orb ${S.chat.open ? "on" : ""}" data-chat aria-expanded="${S.chat.open}" aria-label="${S.chat.open ? "Close chat" : "Ask Lana"}">${S.chat.open ? '<span class="x">×</span>' : SPARK}</button>
      ${TABS.slice(2).map(b).join("")}</div>`;
  }
  function render() {
    renderNav();
    let v;
    try { v = { home: viewHome, money: viewMoney, budget: viewBudget, split: viewSplit, vault: viewVault }[S.tab](); }
    catch (e) { console.error(e); v = `<div class="card" style="margin-top:20px"><span class="tag bad">Something went wrong</span><p>${esc(e.message)}</p><button class="btn ghost" data-reset>Reset demo</button></div>`; }
    main.innerHTML = `<div class="fade-in">${v}</div>`;
    requestAnimationFrame(() => {
      document.querySelectorAll("[data-w]").forEach((el) => (el.style.width = el.dataset.w + "%"));
      document.querySelectorAll("[data-dash]").forEach((el) => el.setAttribute("stroke-dasharray", el.dataset.dash));
    });
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
  const MSG_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M12 3C6.5 3 2 6.8 2 11.5c0 2.6 1.4 4.9 3.6 6.5L5 21.5l4.1-2.1c.9.2 1.9.3 2.9.3 5.5 0 10-3.8 10-8.5S17.5 3 12 3z"/></svg>';
  // The conversation lives in Messages; screens only show which question they answer.
  // Tapping it opens the Messages thread the screen came from.
  const bubbles = (me, thread) => `<button class="askchip" data-thread="${thread}" aria-label="Open this conversation in Messages">${MSG_ICON}<span>“${esc(me)}”</span><b class="chev">›</b></button>`;
  // Hero amount: small currency sign and cents, big dollars.
  function big(c, cls = "") {
    const a = Math.abs(c), d = Math.floor(a / 100).toLocaleString("en-US"), ct = String(a % 100).padStart(2, "0");
    return `<span class="hero-num ${cls}"><span class="cur">${c < 0 ? "−" : ""}$</span>${d}<span class="cents">.${ct}</span></span>`;
  }
  function ring(parts, total, center) {
    const R = 78, C = 2 * Math.PI * R, gap = 6; let off = 0;
    const arcs = parts.map((p) => { const len = Math.max(0, (p.v / total) * C - gap); const a = `<circle r="${R}" cx="100" cy="100" fill="none" stroke="${p.c}" stroke-width="22" stroke-linecap="round" stroke-dasharray="0 ${C}" data-dash="${len} ${C - len}" stroke-dashoffset="${-off}" transform="rotate(-90 100 100)"/>`; off += (p.v / total) * C; return a; }).join("");
    return `<svg viewBox="0 0 200 200" class="ring" role="img" aria-label="${esc(parts.map((p) => p.label + " " + fmt(p.v)).join(", "))}"><circle r="${R}" cx="100" cy="100" fill="none" stroke="var(--line)" stroke-width="22"/>${arcs}</svg><div class="ring-center">${center}</div>`;
  }

  // ======================= HOME =======================
  function viewHome() {
    const snapP = snapshotMonth(), v = mv(snapP), snap = v, f = v.flow, mon = monthLabel(snapP).split(" ")[0];
    const owed = fixtureSplit(), PL = budgetPlan();
    const parts = [
      { label: "Spent", v: f.expenses_cents, c: "var(--spent)" },
      { label: "Saved", v: f.to_savings_cents, c: "var(--accent)" },
      { label: "Invested", v: f.to_investments_cents, c: "var(--accent-2)" },
      { label: "Kept", v: f.retained_cash_cents, c: "var(--ok)" }
    ];
    const stays = f.to_savings_cents + f.to_investments_cents + f.retained_cash_cents;
    const pcts = E.allocate(100, parts.map((p) => p.v)); // largest remainder, so the column sums to 100
    const { unpaid, unpaidCents } = owedSummary();
    return `<div class="home-top"><div><div class="muted small">Sunday, Oct 11</div><h1 style="margin:2px 0 0">Hi, ${esc(DS.user.display_name || "there")}</h1></div>
        <button class="msgbtn" data-messages>${MSG_ICON}Messages</button></div>
      <div class="hero card sky">
        <div class="eyebrow">Net worth</div>
        ${big(snap.net_worth_cents)}
        <div class="split-bar"><span style="flex:${snap.assets_cents}"></span><span style="flex:${snap.liabilities_cents}"></span></div>
        <div class="row small"><span><b class="num">${fmt(snap.assets_cents)}</b> owned</span><span><b class="num">${fmt(snap.liabilities_cents)}</b> owed</span></div>
      </div>
      <button class="card flow-card" data-tab="money" aria-label="${mon} breakdown">
        <div class="row"><span class="eyebrow">${mon}</span><span class="chev">›</span></div>
        <div class="fc-head"><div>${big(stays, "md")}<div class="small muted">stayed with you</div></div><div class="fc-in"><div class="small muted">Came in</div><b class="num">${fmt(f.net_income_cents)}</b></div></div>
        <div class="seg-bar" role="img" aria-label="${esc(parts.map((p) => p.label + " " + fmt(p.v)).join(", "))}">${parts.map((p) => `<span style="flex:${p.v};background:${p.c}"></span>`).join("")}</div>
        <div class="fc-rows">${parts.map((p, i) => `<div class="fc-row"><i class="dot" style="background:${p.c}"></i><span class="grow">${p.label}</span><span class="pct num">${pcts[i]}%</span><b class="num">${fmt(p.v)}</b></div>`).join("")}</div>
      </button>
      <div class="duo">
        <button class="card ink-card" data-tab="split" data-split><div class="ink-num num">${fmt(unpaidCents, { cents: true })}</div><div class="small">owed to you</div><div class="tiny">${unpaid.length ? unpaid.map((q) => esc(q.reviewed_name)).join(", ") : "All settled"}</div></button>
        <button class="card sky2" data-tab="budget"><div class="sky-num num">${fmt(PL.reduction || budgetPlan(true).reduction)}<small>/mo</small></div><div class="small">${PL.reduction ? "plan to save" : "you could save"}</div><div class="tiny">${S.budget.adopted ? "Adopted" : PL.reduction ? "In progress" : "Swipe to review"}</div></button>
      </div>
      <button class="card msg-card" data-messages><div class="row"><span class="eyebrow">Latest in Messages</span><span class="chev">›</span></div>
        <div class="bubble lana" style="max-width:100%;margin-top:8px">You kept ${fmt(stays)} of ${fmt(f.net_income_cents)} in ${mon}. Want a plan to save $150 more?</div></button>`;
  }
  function owedSummary() {
    const owed = fixtureSplit();
    const unpaid = owed.ok ? people().map((p) => owed.r.requests.find((q) => q.contact_id === p.contact_id)).filter(Boolean).filter((q) => reqState(q.contact_id) !== "paid_reported" && reqState(q.contact_id) !== "cancelled") : [];
    return { unpaid, unpaidCents: sum(unpaid, (q) => q.amount_cents) };
  }
  // The Messages thread behind each screen. Lana's lines are written from the same engine numbers.
  function threadSheet(kind) {
    const p = snapshotMonth(), v = mv(p), f = v.flow, mon = monthLabel(p).split(" ")[0];
    const stays = f.to_savings_cents + f.to_investments_cents + f.retained_cash_cents;
    const all = budgetPlan(true), ex = fixtureSplit(), rq = ex.ok ? people().map((x) => ex.r.requests.find((q) => q.contact_id === x.contact_id)).filter(Boolean) : [];
    const T = {
      money: { tab: "money", title: `${mon} breakdown`, msgs: [["me", `Where did my money go in ${mon}?`], ["lana", `You kept ${fmt(stays)} of ${fmt(f.net_income_cents)}. ${v.categories[0].category} was the biggest cost at ${fmt(v.categories[0].total_cents)}, then ${v.categories[1].category.toLowerCase()} at ${fmt(v.categories[1].total_cents)}.`]] },
      budget: { tab: "budget", title: `${P.budget.period} plan`, msgs: [["me", "Help me save $150 next month without changing my rent."], ["lana", `I found ${budgetItems().length} ideas worth up to ${fmt(all.reduction)} a month, and rent stays at ${fmt(all.current.Rent)}. I left out instant coffee since you’ve passed on it before.`], ["lana", "Swipe through them in the app. I’ll ask before buying anything."]] },
      split: { tab: "split", title: `Dinner at ${receipt().merchant}`, msgs: [["me", P.split.transcript], ["me", "📎 Receipt photo"], ["lana", rq.length ? `You’re owed ${fmt(sum(rq, (q) => q.amount_cents), { cents: true })}: ${rq.map((q) => `${q.reviewed_name} ${fmt(q.amount_cents, { cents: true })}`).join(", ")}. Review before I draft the requests?` : "I read the receipt. Review the split in the app?"]] }
    }[kind];
    sheet(`<div class="thread-head"><img src="brand/lana-mark.png" alt="" class="thread-av"><div><b>Lana</b><div class="tiny">iMessage · Today</div></div></div>
      <div class="msg thread">${T.msgs.map(([who, t]) => `<div class="bubble ${who}">${esc(t)}</div>`).join("")}
        <button class="link-card" data-tab="${T.tab}" ${T.tab === "split" ? "data-split" : ""}><img src="brand/lana-mark.png" alt=""><div class="grow"><b>${esc(T.title)}</b><div class="tiny">Open in Lana</div></div><span class="chev">›</span></button></div>
      <div class="sim">◆ Preview of the thread. On iPhone this jumps straight back to your Lana conversation in Messages.</div>
      <div class="btns" style="margin-top:12px"><button class="btn ghost" data-close>Stay here</button><button class="btn accent" data-open-messages>Open Messages</button></div>`);
  }
  function messagesSheet() {
    sheet(`<h3>Lana lives in Messages</h3><p class="small muted" style="margin:6px 0 12px">Ask anything there. This app is for the details.</p>
      <div class="msg"><div class="bubble me">Where did my money go this month?</div><div class="bubble lana">You kept $1,650 of $4,800 in September. Rent was the biggest cost.</div><div class="bubble me">Split dinner with Tanish and Aryan</div><div class="bubble lana">You’re owed $80.60. Review the requests?</div></div>
      <div class="sim">◆ Preview only. Messages isn’t connected here.</div>
      <button class="btn ghost" data-close style="margin-top:12px">Done</button>`);
  }

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
      return `<button class="back" data-tab="home">‹ Home</button><h1>${mon} so far</h1>${seg}
        <div class="card" style="margin-top:14px"><div class="empty"><div class="big-num">Month still open</div><p class="small">Totals appear once it closes.</p></div></div>
        <h2>Pending, not counted</h2>
        <div class="card list"><button class="item" data-tab="split"><div class="grow"><div class="t">Dinner reimbursements owed to you</div><div class="s">${esc(DS.receipts[0].merchant)} · Oct 11 · tracked in Split</div></div><div class="a num">${owed.ok ? fmt(owed.r.outstanding_cents, { cents: true }) : "—"}</div><span class="chev">›</span></button></div>
`;
    }
    const stays = f.to_savings_cents + f.to_investments_cents + f.retained_cash_cents;
    const flowOk = f.net_income_cents === f.expenses_cents + f.to_savings_cents + f.to_investments_cents + f.retained_cash_cents && sum(v.categories, (c) => c.total_cents) === f.expenses_cents;
    const biggest = v.categories[0];
    const answer = `In ${mon} you brought in <b>${fmt(f.net_income_cents)}</b> and spent <b>${fmt(f.expenses_cents)}</b>. ${esc(biggest.category)} was the biggest cost at ${fmt(biggest.total_cents)}. You moved ${fmt(f.to_savings_cents)} to savings and ${fmt(f.to_investments_cents)} to investing, and ${fmt(f.retained_cash_cents)} stayed in checking.`;
    const head = `<button class="back" data-tab="home">‹ Home</button>
      ${bubbles(`Where did my money go in ${mon}?`, "money")}
      <div class="eyebrow" style="margin:14px 4px 0">Stayed with you</div>
      <div style="margin:0 4px 14px">${big(stays)}</div>
      ${seg}
      <div class="seg" role="group" aria-label="View" style="margin-top:8px"><button data-mview="flow" aria-pressed="${S.money.view === "flow"}">In &amp; out</button><button data-mview="bal" aria-pressed="${S.money.view === "bal"}">Balances</button></div>`;
    if (!flowOk) return head + `<div class="card" style="margin-top:12px"><span class="tag bad">Doesn’t reconcile</span><p>These numbers don’t add up, so Lana won’t chart them.</p></div>`;

    if (S.money.view === "bal") {
      const snap = mv(snapshotMonth()), when = dateLabel(DS.as_of);
      const acctRow = (a) => `<button class="item" data-acct="${a.account_id}"><div class="grow"><div class="t">${esc(KIND[a.kind] || a.kind)}</div><div class="s">${esc(a.institution)}${a.opening_balance_cents != null ? ` · ${fmt(a.opening_balance_cents)} on Sep 1` : ""}</div></div><div class="a num">${fmt(a.balance_cents)}</div><span class="chev">›</span></button>`;
      return head + `
        <div class="card" style="margin-top:12px">
          <div class="muted small">Net worth on ${when}</div>
          <div style="margin-top:6px">${big(snap.net_worth_cents)}</div>
          <div class="bar" style="height:10px;margin-top:14px"><span style="width:100%;background:var(--accent)"></span></div>
          <div class="bar" style="height:10px;margin-top:6px"><span style="width:0;background:var(--goes)" data-w="${(snap.liabilities_cents / snap.assets_cents) * 100}"></span></div>
          <div class="legend"><span><i class="dot" style="background:var(--accent)"></i>Assets</span><span><i class="dot" style="background:var(--goes)"></i>Liabilities</span></div>
        </div>
        <h2>What you own</h2><div class="card list">${snap.accounts.filter((a) => a.asset_or_liability === "asset").map(acctRow).join("")}</div>
        <h2>What you owe</h2><div class="card list">${snap.accounts.filter((a) => a.asset_or_liability === "liability").map(acctRow).join("")}</div>
        <p class="note">Balances as of ${when}.</p>`;
    }
    const max = Math.max(...v.categories.map((c) => c.total_cents));
    const chk = v.accounts.find((a) => a.kind === "checking");
    const keptSub = pid === snapshotMonth() && chk && chk.opening_balance_cents != null ? `Checking grew from ${fmt(chk.opening_balance_cents)} to ${fmt(chk.balance_cents)}` : "Left in checking this month";
    return head + `
      <div class="card" style="margin-top:12px">${flowSVG(f)}
        <div class="legend"><span><i class="dot" style="background:var(--goes)"></i>Went out</span><span><i class="dot" style="background:var(--accent)"></i>Stayed with you</span></div></div>
      <div class="checkline">✓ <span class="num">${fmt(f.net_income_cents)} = ${fmt(f.expenses_cents)} + ${fmt(f.to_savings_cents)} + ${fmt(f.to_investments_cents)} + ${fmt(f.retained_cash_cents)}</span></div>
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
  function budgetPlan(all = false) {
    const base = mv(P.budget.base_period), b = P.budget;
    const current = Object.fromEntries(base.categories.map((c) => [c.category, c.total_cents]));
    const items = [...swapsInPlay().map((s) => ({ ...s, savings: swapSavings(s) })), ...b.habits];
    const target = { ...current };
    items.forEach((x) => { if (all || S.budget.accepted[x.id]) target[x.category] -= x.savings; });
    const curTotal = sum(Object.values(current)), tgtTotal = sum(Object.values(target)), reduction = curTotal - tgtTotal;
    const f = base.flow;
    return { current, target, curTotal, tgtTotal, reduction, f, retainedNext: f.retained_cash_cents + reduction };
  }
  const planSig = () => JSON.stringify([S.budget.accepted, S.budget.memoryOn]);

  // Every idea, in category order, swaps first. Decisions live in S.budget.accepted (true/false).
  function budgetItems() {
    return [...swapsInPlay().map((x) => ({ ...x, kind: "swap", savings: swapSavings(x) })), ...P.budget.habits.map((x) => ({ ...x, kind: "habit" }))];
  }
  const decided = (id) => id in S.budget.accepted;
  function budgetCats() {
    const base = mv(P.budget.base_period), items = budgetItems();
    return base.categories.map((c) => {
      const ideas = items.filter((x) => x.category === c.category);
      return { name: c.category, spent: c.total_cents, ideas, pending: ideas.filter((x) => !decided(x.id)), kept: sum(ideas.filter((x) => S.budget.accepted[x.id]), (x) => x.savings), locked: c.category === "Rent" };
    });
  }
  const CAT_ICON = { Rent: "⌂", Groceries: "🛒", Dining: "🍜", "Bills and subscriptions": "📱", Other: "☕️", Transport: "🚆" };
  const shortCat = (n) => n.replace(" and subscriptions", " & subs");
  // What "Keep" can turn into. Every action here is simulated in the preview.
  function execFor(x) {
    if (x.kind === "habit") return { verb: "Remind me", done: "Reminder on", ask: `Want a nudge for “${x.title.toLowerCase()}”?`, body: "Lana will message you at the moment it matters, like before a delivery order." };
    if (x.group === "phone_plan") return { verb: "Switch plan", done: "Switch started", ask: "Switch your phone plan?", body: `Lana opens your carrier with the ${esc(x.to)} selected for ${fmt(x.next)}/mo. You confirm the change there.` };
    return { verb: `Buy for ${fmt(x.next)}`, done: "On next order", ask: `Buy ${esc(x.to.toLowerCase())}?`, body: `Lana adds it to your next grocery order for <b class="num">${fmt(x.next)}</b> instead of ${fmt(x.cur)}. You approve the cart before anything is charged.` };
  }
  function ideaCard(x, i) {
    const tag = x.kind === "swap" ? (x.memory ? '<span class="tag acc">From your history</span>' : '<span class="tag">Swap</span>') : '<span class="tag">Habit</span>';
    return `<div class="idea ${i === 0 ? "top" : ""}" style="--i:${i}" ${i === 0 ? `data-idea="${x.id}"` : 'aria-hidden="true"'}>
      <div class="stamp keep">KEEP</div><div class="stamp skip">SKIP</div>
      <div class="row">${tag}<span class="small muted">${shortCat(x.category)}</span></div>
      <h3 class="idea-t">${esc(x.title)}</h3>
      ${x.kind === "swap" ? `<div class="fromto2"><div><span class="muted small">Now</span><div>${esc(x.from)}</div><b class="num">${fmt(x.cur)}</b></div><div class="arrow">→</div><div><span class="muted small">Instead</span><div>${esc(x.to)}</div><b class="num">${fmt(x.next)}</b></div></div>` : ""}
      <div class="idea-save"><span class="num">${fmt(x.savings)}</span><small>/mo saved</small></div>
      <p class="small idea-why">${esc(x.reason)}</p>
      ${x.kind === "swap" ? '<div class="tiny">Illustrative prices</div>' : ""}
    </div>`;
  }
  function viewBudget() {
    const b = P.budget, PL = budgetPlan(), goal = b.extra_savings_cents, cats = budgetCats(), items = budgetItems();
    const open = cats.filter((c) => !c.locked && c.pending.length);
    if (!S.budget.cat || !cats.find((c) => c.name === S.budget.cat)) S.budget.cat = (open[0] || cats.find((c) => c.ideas.length)).name;
    const cur = cats.find((c) => c.name === S.budget.cat), maxSpent = Math.max(...cats.map((c) => c.spent));
    const changed = S.budget.adopted && S.budget.adopted.sig !== planSig();
    const left = items.filter((x) => !decided(x.id)).length, kept = items.filter((x) => S.budget.accepted[x.id]);
    const pct = Math.min(100, (PL.reduction / goal) * 100);
    const next = open.find((c) => c.name !== cur.name);
    const deck = cur.locked
      ? `<div class="deck-done"><div class="big-ic">🔒</div><b>Rent stays at ${fmt(cur.spent)}</b><div class="small muted">You asked Lana not to touch it.</div></div>`
      : cur.pending.length
        ? `<div class="deck">${cur.pending.slice(0, 3).map(ideaCard).reverse().join("")}</div>
           <div class="deck-btns"><button class="round skip" data-swipe="skip" aria-label="Skip">✕</button><span class="small muted num">${cur.ideas.length - cur.pending.length + 1} of ${cur.ideas.length}</span><button class="round keep" data-swipe="keep" aria-label="Keep">✓</button></div>`
        : `<div class="deck-done"><div class="big-ic">✓</div><b>${shortCat(cur.name)} reviewed</b><div class="small muted">${cur.kept ? `Saving ${fmt(cur.kept)}/mo here` : "Nothing kept here"}</div>${next ? `<button class="btn small accent" data-bcat="${esc(next.name)}" style="margin-top:12px">Next: ${shortCat(next.name)} ›</button>` : ""}</div>`;
    return `${bubbles("Help me save $150 next month without changing my rent.", "budget")}
      <div class="card sky goal-card">
        <div class="row"><span class="eyebrow">${b.period} plan</span>${S.budget.adopted && !changed ? '<span class="pillok">Adopted</span>' : `<span class="tiny">${left ? `${left} ideas left` : "All reviewed"}</span>`}</div>
        <div class="goal-num">${big(PL.reduction, "md")}<span class="small"> of ${fmt(goal)}/mo</span></div>
        <div class="goal-bar"><span data-w="${pct.toFixed(1)}"></span></div>
      </div>
      <h2>Spending by category · Sep</h2>
      <div class="cats" role="tablist">${cats.map((c) => `<button class="cat ${c.name === cur.name ? "on" : ""}" data-bcat="${esc(c.name)}" role="tab" aria-selected="${c.name === cur.name}">
          <span class="cat-ic">${CAT_ICON[c.name] || "•"}</span><span class="cat-n">${shortCat(c.name)}</span><b class="num">${fmt(c.spent)}</b>
          <span class="cat-bar"><i style="width:${((c.spent / maxSpent) * 100).toFixed(0)}%"></i></span>
          <span class="cat-plan small">${c.locked ? "Stays the same" : c.kept ? `Plan ${fmt(c.spent - c.kept)}` : c.ideas.length ? `Up to −${fmt(sum(c.ideas, (x) => x.savings))}` : "On track"}</span>
          <span class="cat-s">${c.locked ? "Locked" : !c.ideas.length ? "No ideas" : c.pending.length ? `${c.pending.length} idea${c.pending.length > 1 ? "s" : ""}` : c.kept ? `−${fmt(c.kept)}` : "Reviewed"}</span></button>`).join("")}</div>
      ${deck}
      ${S.budget.history.length ? `<div style="text-align:center"><button class="small" data-undo style="min-height:44px;color:var(--accent)">Undo last</button></div>` : ""}
      <h2>Your plan · ${fmt(PL.reduction)}/mo</h2>
      <div class="card list">${kept.length ? kept.map((x) => { const e = S.budget.exec[x.id]; return `<div class="item"><div class="grow"><div class="t">${esc(x.title)}</div><div class="s">${esc(shortCat(x.category))}${e ? ` · <span style="color:var(--ok)">${esc(execFor(x).done)}</span>` : ""}</div></div>${!e ? `<button class="btn small ghost" data-exec="${x.id}">${x.kind === "habit" ? "Remind" : x.group === "phone_plan" ? "Switch" : "Buy"}</button>` : ""}<span class="num a" style="color:var(--accent)">${fmt(x.savings)}</span></div>`; }).join("") : '<div class="empty small">Swipe right on ideas you like.</div>'}</div>
      ${Object.keys(S.budget.exec).length ? '<div class="sim" style="margin:0 4px 8px">◆ Simulated. No orders, reminders or plan switches happen in this preview.</div>' : ""}
      <button class="btn accent" data-adopt ${!kept.length || (S.budget.adopted && !changed) ? "disabled" : ""}>${S.budget.adopted && !changed ? "Plan adopted" : "Adopt plan"}</button>
      <h2>Your rules</h2>
      <div class="card flat"><div class="chips">${b.constraints.filter((c) => S.budget.memoryOn || c.id !== "c_instant").map((c) => `<span class="chip rule" title="${esc(c.source)}">✓ ${esc(c.text)}</span>`).join("")}</div>
        <button class="item" data-why style="display:flex;width:100%;min-height:44px;align-items:center;margin-top:8px"><span class="grow" style="color:var(--accent);font-weight:600;text-align:left">Why these ideas? ${b.excluded.filter((x) => S.budget.memoryOn || !x.memory).length} left out</span><span class="chev">›</span></button></div>`;
  }
  function decide(id, keep) {
    const x = budgetItems().find((i) => i.id === id); if (!x || decided(id)) return;
    S.budget.accepted[id] = keep; S.budget.history.push(id); render();
    if (keep) execSheet(id);
  }
  function execSheet(id) {
    const x = budgetItems().find((i) => i.id === id), e = execFor(x);
    sheet(`<div class="exec-ic">${x.kind === "habit" ? "⏰" : x.group === "phone_plan" ? "📱" : "🛒"}</div>
      <h3 style="text-align:center">${e.ask}</h3>
      <p class="small" style="text-align:center;margin:8px 8px 14px">${e.body}</p>
      <div class="kv"><span class="muted">Saves</span><span class="num" style="color:var(--accent);font-weight:650">${fmt(x.savings)}/mo</span></div>
      <div class="sim">◆ Simulated. Nothing is bought, sent or switched in this preview.</div>
      <div class="btns" style="margin-top:14px"><button class="btn ghost" data-close>Just add to plan</button><button class="btn accent" data-exec-go="${id}">${e.verb}</button></div>`);
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

  // ======================= RECEIPTS (hub) =======================
  // Any receipt in, then choose what to do with it. Split runs the full engine-backed flow for the
  // dinner fixture; Pay and Add to budget are simulated confirmations.
  function allReceipts() {
    const d = receipt();
    return [{ receipt_id: d.receipt_id, kind: "restaurant", merchant: d.merchant, date: d.date, category: "Dining", total_cents: d.total_cents, paid_with: "Demo Card", items: d.items, fixture: true }, ...P.receipts];
  }
  const RC_ICON = { restaurant: "🍽", bill: "⚡️", store: "🛒" };
  function viewReceipts() {
    const R = S.rcpt, list = allReceipts(), cur = list.find((r) => r.receipt_id === R.open);
    const upload = `<div class="drop"><div class="drop-ic">${ICONS.split}</div><b>Add any receipt</b><div class="small muted">Dinner, groceries, a bill or an invoice. Lana reads it on your phone.</div>
        <label class="btn small accent" style="cursor:pointer;margin-top:12px">Upload photo<input type="file" accept="image/*" data-rcpt-upload hidden></label></div>`;
    const card = (r) => { const d = R.done[r.receipt_id]; return `<button class="rc-row" data-rcpt="${r.receipt_id}"><span class="rc-ic">${RC_ICON[r.kind]}</span><div class="grow"><div class="t">${esc(r.merchant)}</div><div class="s">${dateLabel(r.date + "T12:00:00-07:00")}${r.due ? ` · due ${dateLabel(r.due + "T12:00:00-07:00")}` : ""}${d ? ` · <span style="color:var(--ok)">${esc(d)}</span>` : r.fixture ? "" : " · sample"}</div></div><b class="num">${fmt(r.total_cents, { cents: true })}</b><span class="chev">›</span></button>`; };
    if (!cur) return `${bubbles("Here’s the receipt from dinner", "split")}<h1>Receipts</h1>${upload}
      ${R.upload ? '<div class="sim" style="margin:-4px 4px 10px">◆ Photo received. This preview reads one of the samples below; on iPhone the photo is read on-device.</div>' : ""}
      <h2>Recent</h2><div class="card list rc-list">${list.map(card).join("")}</div>`;
    const isBill = cur.kind === "bill", d = R.done[cur.receipt_id];
    const acts = [
      ["split", "👥", "Split it", cur.fixture ? "Assign items and request shares" : "Share evenly with friends"],
      ["pay", "💳", isBill ? "Pay it" : "Paid", isBill ? `From Checking · due ${dateLabel(cur.due + "T12:00:00-07:00")}` : `Already paid with ${cur.paid_with}`],
      ["budget", "📊", "Add to budget", `File under ${shortCat(cur.category)}`],
      ["remind", "⏰", isBill ? "Remind me" : "Keep for returns", isBill ? "A nudge 2 days before it’s due" : "Saved with the card you used"]
    ];
    return `<button class="back" data-rcpt-home>‹ Receipts</button>
      <div class="card rc-hero"><div class="row"><span class="rc-ic big">${RC_ICON[cur.kind]}</span><span class="tag">${cur.fixture ? "From Messages" : "Sample"}</span></div>
        <div class="t" style="font-weight:650;margin-top:10px">${esc(cur.merchant)}</div><div class="small muted">${dateLabel(cur.date + "T12:00:00-07:00")} · ${cur.items.length} lines · ${shortCat(cur.category)}</div>
        ${big(cur.total_cents, "md")}
        <div class="rc-lines">${cur.items.slice(0, 4).map((i) => `<div class="kv"><span class="muted">${esc(i.description)}</span><span class="num">${fmt(i.extended_price_cents, { cents: true })}</span></div>`).join("")}${cur.items.length > 4 ? `<div class="small muted">+ ${cur.items.length - 4} more</div>` : ""}</div></div>
      ${d ? `<div class="checkline">✓ ${esc(d)}</div>` : ""}
      <h2>What should Lana do?</h2>
      <div class="acts">${acts.map(([id, ic, t, s]) => `<button class="act" data-ract="${id}" ${id === "pay" && !isBill ? "disabled" : ""}><span class="act-ic">${ic}</span><b>${t}</b><span class="small muted">${s}</span></button>`).join("")}</div>`;
  }
  function receiptAction(act) {
    const r = allReceipts().find((x) => x.receipt_id === S.rcpt.open);
    if (act === "split" && r.fixture) { S.tab = "split"; S.rcpt.splitting = true; top(); return render(); }
    const ppl = people().filter((p) => p.contact_id !== payerId());
    const even = E.allocate(r.total_cents, Array(ppl.length + 1).fill(1));
    const C = {
      split: { ic: "👥", h: `Split ${fmt(r.total_cents, { cents: true })} evenly?`, b: `${ppl.map((p, i) => `${esc(p.reviewed_name)} owes <b class="num">${fmt(even[i + 1], { cents: true })}</b>`).join(", ")}. Your share is ${fmt(even[0], { cents: true })}. Lana drafts the requests for you to review.`, go: "Draft requests", done: "Split drafted" },
      pay: { ic: "💳", h: `Pay ${esc(r.merchant)}?`, b: `<b class="num">${fmt(r.total_cents, { cents: true })}</b> from Checking (balance ${fmt(DS.accounts.find((a) => a.kind === "checking").balance_cents)}). You confirm with Face ID before anything is sent.`, go: `Pay ${fmt(r.total_cents, { cents: true })}`, done: "Payment scheduled" },
      budget: { ic: "📊", h: `Add to ${shortCat(r.category)}?`, b: `Counts <b class="num">${fmt(r.total_cents, { cents: true })}</b> toward your ${shortCat(r.category)} budget for October.`, go: "Add to budget", done: `Added to ${shortCat(r.category)}` },
      remind: { ic: "⏰", h: r.kind === "bill" ? "Remind you before it’s due?" : "Keep for returns?", b: r.kind === "bill" ? `Lana messages you on ${dateLabel(r.due.replace(/\d\d$/, (d) => String(+d - 2).padStart(2, "0")) + "T12:00:00-07:00")}.` : "Lana keeps the receipt and the card you used, so returns and warranty claims are one tap.", go: r.kind === "bill" ? "Remind me" : "Keep it", done: r.kind === "bill" ? "Reminder set" : "Kept for returns" }
    }[act];
    sheet(`<div class="exec-ic">${C.ic}</div><h3 style="text-align:center">${C.h}</h3><p class="small" style="text-align:center;margin:8px 8px 14px">${C.b}</p>
      <div class="sim">◆ Simulated. Nothing is paid, sent or filed in this preview.</div>
      <div class="btns" style="margin-top:14px"><button class="btn ghost" data-close>Not now</button><button class="btn accent" data-ract-go="${act}">${C.go}</button></div>`);
    S.rcpt.pending = C.done;
  }
  function viewSplit() {
    if (!S.rcpt.splitting) return viewReceipts();
    const rc = receipt(), st = S.split, merchant = rc.merchant, dateStr = dateLabel(rc.date + "T12:00:00-07:00");
    const stepper = `<div class="stepper">${STEPS.map((_, i) => `<span class="${i <= st.step ? "on" : ""}"></span>`).join("")}</div>`;
    const nav = (next, label, dis) => `<div class="btns" style="margin-top:14px">${st.step > 0 ? '<button class="btn ghost" data-back style="width:auto;padding:0 18px">Back</button>' : ""}<button class="btn accent" data-next="${next}" ${dis ? "disabled" : ""}>${label}</button></div>`;
    const head = (t, s) => `<button class="back" data-rcpt-home>‹ Receipts</button>${bubbles("I paid for dinner with Tanish and Aryan…", "split")}${stepper}<p class="muted small" style="margin:0 4px">Step ${st.step + 1} of ${STEPS.length} · ${STEPS[st.step]}</p><h1>${t}</h1>${s ? `<p class="sub">${s}</p>` : ""}`;

    if (st.step === 0) {
      const wave = Array.from({ length: 34 }, (_, i) => `<i style="height:${6 + Math.round(Math.abs(Math.sin(i * 1.7) * 18 + Math.cos(i * 0.6) * 4))}px"></i>`).join("");
      const both = st.receipt && st.voice;
      return head("Split dinner", "") + `
        <div class="card"><div class="row"><h3>Receipt</h3>${st.receipt ? '<span class="tag acc">Received</span>' : '<span class="tag">Waiting</span>'}</div>
          ${st.upload ? `<img src="${st.upload}" alt="Your uploaded receipt" style="width:100%;max-height:160px;object-fit:cover;border-radius:12px;margin-top:10px">` : ""}
          ${st.receipt ? `<p class="small muted" style="margin:8px 0 0">${st.upload ? "Your photo is shown. This preview reads the sample receipt; on iPhone the photo is read on-device." : `${esc(merchant)} · ${dateStr}`}</p>` : ""}
          <div class="btns" style="margin-top:12px"><button class="btn small ${st.receipt ? "ghost" : ""}" data-sample-receipt>Use sample receipt</button>
          <label class="btn small ghost" style="cursor:pointer">Upload photo<input type="file" accept="image/*" data-upload hidden></label></div></div>
        <div class="card"><div class="row"><h3>Voice note</h3>${st.voice ? '<span class="tag acc">Transcribed</span>' : '<span class="tag">Waiting</span>'}</div>
          ${st.voice ? `<div class="row" style="margin-top:10px;gap:10px"><span class="avatar" style="background:var(--accent);color:#fff">▶</span><div class="wave" aria-hidden="true">${wave}</div><span class="small muted num">0:07</span></div>
          <p style="margin:10px 0 0;font-size:15px">“${esc(P.split.transcript)}”</p><div class="sim">◆ Sample · on-device on iPhone</div>` : ""}
          <div style="margin-top:12px"><button class="btn small ${st.voice ? "ghost" : ""}" data-sample-voice>Use sample voice note</button></div></div>
        <div class="card flat"><div class="row"><span class="small">Messages delivery</span><span class="pill ${both ? "ok" : "muted"}">${both ? "Completed · 2 of 2" : st.receipt || st.voice ? "Pending · 1 of 2" : "Waiting"}</span></div>
          <div class="sim">◆ Simulated</div></div>
        ${nav(1, "Read receipt", !both)}`;
    }
    if (st.step === 1) {
      const ln = (n, c, cls = "") => `<div class="row ${cls}"><span>${esc(n)}</span><span>${fmt(c, { cents: true })}</span></div>`;
      const sr = splitResult(), mismatch = !sr.ok && sr.e.code === "RECEIPT_MISMATCH";
      const diff = rc.total_cents - (rc.subtotal_cents + rc.tax_cents + st.tip);
      return head("Check the receipt", mismatch ? "Fix the tip to continue." : "") + `
        <div class="receipt" aria-label="Receipt image"><div class="c"><b>${esc(merchant.toUpperCase())}</b><br>${esc(rc.date)}</div><br>
          ${rc.items.map((i) => ln(i.description, i.extended_price_cents)).join("")}<br>${ln("Subtotal", rc.subtotal_cents)}${ln("Tax", rc.tax_cents)}${ln("Tip", rc.tip_cents, st.tipFixed ? "" : "hl")}<b>${ln("TOTAL", rc.total_cents)}</b></div>
        <div class="card" style="margin-top:14px">
          <div class="small muted" style="margin-bottom:4px">What Lana read</div>
          ${rc.items.map((i) => `<div class="field"><span>${esc(i.description)}</span><span class="num">${fmt(i.extended_price_cents, { cents: true })}</span></div>`).join("")}
          <div class="field"><span>Tax</span><span class="num">${fmt(rc.tax_cents, { cents: true })}</span></div>
          <div class="field ${st.tipFixed ? "" : "flag"}"><span>Tip ${st.tipFixed ? '<span class="tag acc">Corrected</span>' : `<span class="tag warn">Unsure · ${Math.round(P.split.ocr_misread.confidence * 100)}%</span>`}</span><input inputmode="decimal" aria-label="Tip amount" data-tip value="${(st.tip / 100).toFixed(2)}"></div>
          <div class="kv total"><span>Receipt total</span><span class="num">${fmt(rc.total_cents, { cents: true })}</span></div>
          ${mismatch ? `<div class="sim" style="color:var(--bad)">✕ Off by ${fmt(Math.abs(diff), { cents: true })}. Requests stay blocked until this matches.</div>` : '<div class="sim" style="color:var(--accent)">✓ Items, tax and tip match the total</div>'}
          </div>
        ${nav(2, "Assign items", mismatch)}`;
    }
    if (st.step === 2) {
      const ppl = people(), opts = [...ppl.map((p) => [p.contact_id, p.reviewed_name]), ["shared", "Shared"]];
      return head("Who had what", "") + `
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
      return head("You’re owed", "") + `<div style="margin:-4px 4px 14px">${big(r.outstanding_cents)}</div>` + `
        ${ordered.map((x) => `<div class="card"><div class="row">${av(x.contact_id)}<div class="grow" style="margin-left:4px"><div style="font-weight:650">${esc(person(x.contact_id).reviewed_name)}</div><div class="small muted num">${fmt(x.items_cents, { cents: true })} food + ${fmt(x.tax_tip_cents, { cents: true })} tax &amp; tip</div></div><div class="big-num num" style="font-size:24px">${fmt(x.total_cents, { cents: true })}</div></div>${x.contact_id === payerId() ? '<div class="small muted" style="margin-top:6px">Your share. You paid the bill.</div>' : ""}</div>`).join("")}
        <div class="checkline">${ok ? "✓" : "✕"} <span class="num">${ordered.map((x) => fmt(x.total_cents, { cents: true })).join(" + ")} = ${fmt(total, { cents: true })}</span></div>
        ${nav(4, "Prepare requests", !ok)}`;
    }
    if (st.step === 4) {
      return head("Requests", "You review each one first.") + `
        ${r.requests.map((q) => reqCard(q)).join("")}
        <p class="note">Paid status is what you report.</p>
        ${nav(5, "Set up follow-ups")}`;
    }
    return head("Follow-ups", "") + `
      <div class="card"><div class="row"><div><div class="small muted">Demo clock</div><div style="font-weight:650">${st.clock ? "Mon, Oct 12 · 10:00 AM" : "Sun, Oct 11 · 8:40 PM"}</div></div>
      <button class="btn small ${st.clock ? "ghost" : ""}" data-clock>${st.clock ? "Back to today" : "Jump to tomorrow"}</button></div>
      <div class="sim">◆ Demo clock</div></div>
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
      ${r && st.clock && !paid && !disputed && s !== "cancelled" ? `<div class="bubble lana" style="margin-top:10px;max-width:100%">${esc(text)}</div><div class="sim">◆ Simulated send</div>` : ""}
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

  // ======================= CHAT =======================
  // Preview replies are scripted from the same engine results the screens use. On iPhone the
  // on-device model answers; nothing here calls a model.
  const SUGGEST = ["Where did my money go?", "What’s my net worth?", "Who owes me?", "How do I save $150?", "Which accounts are connected?"];
  function lanaReply(raw) {
    const q = raw.toLowerCase(), has = (...w) => w.some((x) => q.includes(x));
    const p = snapshotMonth(), v = mv(p), f = v.flow, mon = monthLabel(p).split(" ")[0];
    const stays = f.to_savings_cents + f.to_investments_cents + f.retained_cash_cents;
    const cat = v.categories.find((c) => q.includes(c.category.toLowerCase().split(" ")[0]));
    if (cat) return { text: `${cat.category} was ${fmt(cat.total_cents)} in ${mon}, across ${cat.transaction_ids.length} ${cat.transaction_ids.length === 1 ? "payment" : "payments"}.`, actions: [["money", `Open ${mon}`]] };
    if (has("owe", "split", "dinner", "venmo", "paid", "tanish", "aryan")) {
      const { unpaid, unpaidCents } = owedSummary();
      return unpaid.length
        ? { text: `You’re owed ${fmt(unpaidCents, { cents: true })} for dinner: ${unpaid.map((r) => `${r.reviewed_name} ${fmt(r.amount_cents, { cents: true })}`).join(", ")}. Nothing is sent until you approve it.`, actions: [["split", "Review split"]] }
        : { text: "Everyone has settled up for dinner.", actions: [["split", "Open split"]] };
    }
    if (has("save", "budget", "plan", "150", "cut")) {
      const PL = budgetPlan(), top = swapsInPlay().filter((x) => S.budget.accepted[x.id]).sort((x, y) => swapSavings(y) - swapSavings(x)).slice(0, 2);
      if (!PL.reduction) { const all = budgetPlan(true); return { text: `I found ${budgetItems().length} ideas worth up to ${fmt(all.reduction)} a month, with rent unchanged. Swipe through them by category and I’ll ask before buying anything.`, actions: [["budget", "Start swiping"]] }; }
      if (!top.length) return { text: `So far your plan saves ${fmt(PL.reduction)} a month from habit changes.`, actions: [["budget", "Keep going"]] };
      return { text: `Your plan saves ${fmt(PL.reduction)} a month with rent unchanged. Biggest wins: ${top.map((x) => `${x.title.toLowerCase()} (${fmt(swapSavings(x))})`).join(" and ")}.`, actions: [["budget", "Review plan"]] };
    }
    if (has("worth", "net", "assets", "debt")) return { text: `Your net worth is ${fmt(v.net_worth_cents)}: ${fmt(v.assets_cents)} you own minus ${fmt(v.liabilities_cents)} you owe, as of ${dateLabel(DS.as_of)}.`, actions: [["vault", "See accounts"]] };
    if (has("account", "connect", "bank", "card", "loan", "balance")) return { text: `${v.accounts.length} accounts are connected across ${new Set(v.accounts.map((a) => a.institution)).size} institutions, all demo data synced ${dateLabel(DS.as_of)}.`, actions: [["vault", "Open accounts"]] };
    if (has("where", "spend", "spent", "go", "month", "money", "income")) {
      const big = v.categories[0];
      return { text: `In ${mon} you kept ${fmt(stays)} of ${fmt(f.net_income_cents)}. ${big.category} was the biggest cost at ${fmt(big.total_cents)}.`, actions: [["money", `Open ${mon}`]] };
    }
    if (has("hi", "hey", "hello", "thanks")) return { text: "Hi! Try asking where your money went or who owes you." };
    return { text: "In this preview I can answer about spending, net worth, your plan, the dinner split and connected accounts. On iPhone, the on-device model handles open questions." };
  }
  function chatHTML() {
    const c = S.chat;
    return `<div class="chat-head"><img class="lana-av" src="brand/lana-mark.png" alt=""><div class="grow"><b>Lana</b><div class="tiny">Preview replies from your demo numbers</div></div>
        <button class="chat-x" data-chat aria-label="Close chat">×</button></div>
      <div class="chat-log" id="chatLog" aria-live="polite">
        ${c.msgs.map((m) => `<div class="bubble ${m.from === "me" ? "me" : "lana"}">${esc(m.text)}${m.actions ? `<div class="bub-acts">${m.actions.map(([t, l]) => `<button data-tab="${t}" ${t === "split" ? "data-split" : ""}>${esc(l)} ›</button>`).join("")}</div>` : ""}</div>`).join("")}
        ${c.typing ? '<div class="bubble lana typing" aria-label="Lana is typing"><i></i><i></i><i></i></div>' : ""}
      </div>
      <div class="chat-sugs">${SUGGEST.map((t) => `<button data-ask="${esc(t)}">${esc(t)}</button>`).join("")}</div>
      <form class="chat-in" id="chatForm" autocomplete="off"><input id="chatIn" placeholder="Ask about your money" aria-label="Message Lana" maxlength="200"><button type="submit" aria-label="Send">↑</button></form>`;
  }
  function renderChat() {
    let el = $("#chat");
    if (!el) { el = document.createElement("div"); el.id = "chat"; el.className = "chat"; el.setAttribute("role", "dialog"); el.setAttribute("aria-label", "Chat with Lana"); $("#phone").appendChild(el); }
    const keep = $("#chatIn") ? $("#chatIn").value : "";
    el.innerHTML = chatHTML(); el.classList.toggle("open", S.chat.open);
    $("#chatIn").value = keep;
    const log = $("#chatLog"); log.scrollTop = log.scrollHeight;
  }
  function toggleChat(open = !S.chat.open) {
    S.chat.open = open; renderNav(); renderChat();
    if (open) setTimeout(() => { const i = $("#chatIn"); if (i && matchMedia("(pointer:fine)").matches) i.focus(); }, 250);
  }
  function ask(text) {
    text = text.trim(); if (!text || S.chat.typing) return;
    S.chat.msgs.push({ from: "me", text }); S.chat.typing = true; renderChat();
    setTimeout(() => { S.chat.typing = false; S.chat.msgs.push({ from: "lana", ...lanaReply(text) }); renderChat(); }, 650);
  }

  // ======================= ACCOUNTS (was Vault) =======================
  const INST = { "Chase": ["#117ACA", "#0B4F8A"], "Robinhood": ["#CCFF00", "#00C805"], "Capital One": ["#D03027", "#004977"], "Sallie Mae": ["#0F2C52", "#1D5FA8"] };
  const mono = (inst, size = 40) => { const [a, b] = INST[inst] || ["#8E8E93", "#636366"]; return `<span class="mono" style="width:${size}px;height:${size}px;background:linear-gradient(145deg,${a},${b})">${esc(inst[0])}</span>`; };
  let vaultTimer;
  function viewVault() {
    const snap = mv(snapshotMonth()), accts = snap.accounts, insts = [...new Set(accts.map((a) => a.institution))], when = dateLabel(DS.as_of);
    const groups = insts.map((inst) => {
      const list = accts.filter((a) => a.institution === inst);
      return `<div class="card inst">
        <div class="inst-head">${mono(inst)}<div class="grow"><div class="t">${esc(inst)}</div><div class="s"><i class="live"></i>Connected · synced ${when}</div></div></div>
        <div class="list">${list.map((a) => {
          const d = a.opening_balance_cents != null ? a.balance_cents - a.opening_balance_cents : 0, liab = a.asset_or_liability === "liability";
          return `<button class="item" data-acct="${a.account_id}"><div class="grow"><div class="t">${esc(KIND[a.kind] || a.kind)}</div><div class="s">${liab ? "You owe" : d ? `${fmt(d, { plus: true })} in September` : "No change in September"}</div></div><span class="a num" ${liab ? 'style="color:var(--ink-2)"' : ""}>${liab ? "−" : ""}${fmt(a.balance_cents)}</span><span class="chev">›</span></button>`;
        }).join("")}</div></div>`;
    }).join("");
    const services = [
      ["Messages", "Where you talk to Lana", "Simulated here"],
      ["Venmo", "Request handoff only. Lana never holds your login.", "Handoff"],
      ["Purchase history", "Past swap decisions for your plan", "Simulated here"]
    ];
    return `<div class="row" style="margin:6px 4px 2px"><h1 style="margin:0">Accounts</h1><button class="btn small ghost" data-connect>+ Add</button></div>
      <p class="sub">${accts.length} accounts at ${insts.length} institutions · sample data</p>
      <div class="card stack-card">
        <div class="eyebrow">Net worth</div>
        ${big(snap.net_worth_cents, "md")}
        <div class="stack-bar">${accts.map((a) => `<span style="flex:${a.balance_cents};background:linear-gradient(145deg,${(INST[a.institution] || ["#8E8E93"])[0]},${(INST[a.institution] || ["", "#636366"])[1]})${a.asset_or_liability === "liability" ? ";opacity:.35" : ""}" title="${esc(a.institution)} ${esc(KIND[a.kind])}"></span>`).join("")}</div>
        <div class="row small"><span><b class="num">${fmt(snap.assets_cents)}</b> <span class="muted">owned</span></span><span><b class="num">${fmt(snap.liabilities_cents)}</b> <span class="muted">owed (faded)</span></span></div>
      </div>
      ${groups}
      <h2>Also connected</h2>
      <div class="card list">${services.map(([n, d, st]) => `<div class="item"><span class="svc">${n[0]}</span><div class="grow"><div class="t">${n}</div><div class="s">${d}</div></div><span class="tag ${st === "Handoff" ? "" : "warn"}">${st}</span></div>`).join("")}</div>
      <h2>Sign-in keys</h2>${keysBlock()}
      <h2>Privacy</h2><div class="card flat small">
      <p style="margin:0 0 8px"><b>The model and financial reasoning run on your phone.</b></p>
      <p style="margin:0 0 8px">Messages you send Lana pass through a messaging provider, and connected services receive what they need to work.</p>
      <p style="margin:0">Lana’s model sees connection names and what they’re allowed to do. It never sees passwords, tokens or verification codes.</p></div>
      <button class="demo-link" id="demoPill">Demo data · reset or switch theme</button>
      <h2>Approvals</h2><div class="card list">${S.log.length ? S.log.map((l) => `<div class="item"><div class="grow"><div style="font-weight:550">${esc(l.text)}</div><div class="s">${esc(l.at)}</div></div><span class="tag ${l.kind === "approved" ? "acc" : ""}">${esc(l.kind)}</span></div>`).join("") : '<div class="empty small">Nothing approved yet.</div>'}</div>`;
  }
  // The credentials that keep these connections working, behind Face ID plus a code.
  function keysBlock() {
    const v = S.vault, sim = '<div class="sim">◆ Simulated. No Face ID or code check in this preview.</div>';
    const lockIcon = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><rect x="4" y="10" width="16" height="11" rx="2.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>';
    if (v.stage === "locked" || v.stage === "bio") {
      return `<div class="card"><div class="row"><span class="keyic">${lockIcon}</span><div class="grow"><div class="t" style="font-weight:600">${P.vault.length} keys · Locked</div><div class="s small muted">Face ID, then your authenticator code</div></div>
        <button class="btn small accent" data-bio ${v.stage === "bio" ? "disabled" : ""}>${v.stage === "bio" ? "Checking…" : "Unlock"}</button></div>
        ${v.err ? `<p class="small" style="color:var(--bad);margin:10px 0 0">${esc(v.err)}</p>` : ""}
        ${sim}<button class="small muted" data-bio-fail style="min-height:44px;text-decoration:underline">Show a failed attempt</button></div>`;
    }
    if (v.stage === "otp") {
      return `<div class="card"><div class="t" style="font-weight:600;text-align:center">Face ID passed. Enter your 6-digit code.</div>
        <div class="otp">${Array.from({ length: 6 }, (_, i) => `<input inputmode="numeric" maxlength="1" aria-label="Digit ${i + 1}" data-otp="${i}">`).join("")}</div>
        ${v.err ? `<p class="small" style="color:var(--bad);text-align:center">${esc(v.err)}</p>` : ""}
        <div class="btns"><button class="btn ghost" data-lock>Cancel</button><button class="btn accent" data-otp-go>Verify</button></div>${sim}</div>`;
    }
    const left = Math.max(0, Math.ceil((v.lockAt - Date.now()) / 1000));
    return `<div class="card"><div class="row"><b>Unlocked</b><span class="pill ok">Locks in <span data-countdown class="num">${left}s</span></span></div>
      <div class="list">${P.vault.map((s) => `<div class="item"><div class="grow"><div class="t">${esc(s.label)}</div><div class="s">${esc(s.scope)}</div><div class="secret" style="margin-top:4px">${v.revealed[s.id] ? esc(s.value) : "•••• •••• ••••"}</div></div><button class="btn small ghost" data-reveal="${s.id}">${v.revealed[s.id] ? "Hide" : "Show"}</button></div>`).join("")}</div>
      <p class="note">Synthetic demo values. Locks after 60 seconds or when you leave the app.</p>
      <button class="btn" data-lock>Lock now</button>${sim}</div>`;
  }
  function startVaultTimer() {
    clearInterval(vaultTimer);
    vaultTimer = setInterval(() => {
      if (S.vault.stage !== "unlocked") return clearInterval(vaultTimer);
      const left = Math.ceil((S.vault.lockAt - Date.now()) / 1000);
      if (left <= 0) return lockVault("Keys locked after 60 seconds.");
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

  // ---------- swipe deck ----------
  function flyOut(el, keep) {
    el.style.transition = "transform .3s ease-in, opacity .3s ease-in";
    el.style.transform = `translateX(${keep ? 520 : -520}px) rotate(${keep ? 24 : -24}deg)`; el.style.opacity = "0";
    setTimeout(() => decide(el.dataset.idea, keep), 220);
  }
  let drag = null;
  document.addEventListener("pointerdown", (e) => {
    const el = e.target.closest(".idea.top"); if (!el) return;
    drag = { el, x0: e.clientX, y0: e.clientY, dx: 0 }; el.setPointerCapture(e.pointerId); el.style.transition = "none";
  });
  document.addEventListener("pointermove", (e) => {
    if (!drag) return; const dx = e.clientX - drag.x0; drag.dx = dx;
    drag.el.style.transform = `translateX(${dx}px) rotate(${dx / 18}deg)`;
    drag.el.style.setProperty("--keep", Math.max(0, Math.min(1, dx / 90))); drag.el.style.setProperty("--skip", Math.max(0, Math.min(1, -dx / 90)));
  });
  const endDrag = () => {
    if (!drag) return; const { el, dx } = drag; drag = null;
    if (Math.abs(dx) > 90) return flyOut(el, dx > 0);
    el.style.transition = "transform .35s cubic-bezier(.2,.9,.3,1.2)"; el.style.transform = ""; el.style.setProperty("--keep", 0); el.style.setProperty("--skip", 0);
  };
  document.addEventListener("pointerup", endDrag); document.addEventListener("pointercancel", endDrag);
  document.addEventListener("keydown", (e) => { if (S && S.tab === "budget" && !e.target.closest("input") && $(".idea.top") && (e.key === "ArrowRight" || e.key === "ArrowLeft")) flyOut($(".idea.top"), e.key === "ArrowRight"); });

  // ---------- events ----------
  document.addEventListener("input", (e) => {
    const t = e.target;
    if (t.matches("[data-tip]")) {
      const v = Math.round(parseFloat(t.value.replace(/[^0-9.]/g, "")) * 100);
      if (!isNaN(v)) { S.split.tip = v; S.split.tipFixed = v === receipt().tip_cents; const pos = t.selectionStart; render(); const n = $("[data-tip]"); if (n) { n.focus(); try { n.setSelectionRange(pos, pos); } catch (_) {} } }
    }
    if (t.matches("[data-otp]")) { t.value = t.value.replace(/\D/g, "").slice(0, 1); if (t.value) { const n = $(`[data-otp="${+t.dataset.otp + 1}"]`); if (n) n.focus(); } }
  });
  document.addEventListener("submit", (e) => {
    if (e.target.id !== "chatForm") return;
    e.preventDefault(); const i = $("#chatIn"); const t = i.value; i.value = ""; ask(t);
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && S && S.chat.open) toggleChat(false); });
  document.addEventListener("change", (e) => {
    const t = e.target;
    if (t.matches("[data-rcpt-upload]") && t.files[0]) { S.rcpt.upload = true; toast("Photo received. Pick a sample below to continue."); return render(); }
    if (t.matches("[data-upload]") && t.files[0]) { const r = new FileReader(); r.onload = () => { S.split.upload = r.result; S.split.receipt = true; render(); }; r.readAsDataURL(t.files[0]); }
  });
  document.addEventListener("click", (e) => {
    const t = e.target.closest("button,[data-close]"); if (!t || !S) return;
    const d = t.dataset;
    if (d.tab === "split") S.rcpt.splitting = "split" in d;
    if (d.tab) { closeSheet(); if (S.chat.open) toggleChat(false); return go(d.tab); }
    if ("chat" in d) return toggleChat();
    if (d.ask) return ask(d.ask);
    if ("connect" in d) return toast("Simulated. Linking a new account isn’t in this preview.");
    if (t.id === "demoPill") return demoSheet();
    if ("messages" in d) return messagesSheet();
    if (d.thread) return threadSheet(d.thread);
    if ("openMessages" in d) { closeSheet(); return toast("Simulated. On iPhone this opens your Lana thread in Messages."); }
    if ("close" in d) return closeSheet();
    if ("reset" in d) { closeSheet(); clearInterval(vaultTimer); S = initialState(); toast("Demo reset"); top(); renderChat(); return render(); }
    if ("themeToggle" in d) { const r = document.documentElement; const dark = r.dataset.theme ? r.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches; r.dataset.theme = dark ? "light" : "dark"; return; }
    if (d.period) { S.money.period = d.period; return render(); }
    if (d.mview) { S.money.view = d.mview; return render(); }
    if (d.cat) return catSheet(d.cat);
    if (d.xfer) return xferSheet(d.xfer);
    if (d.acct) return acctSheet(d.acct);
    if (d.rcpt) { S.rcpt.open = d.rcpt; top(); return render(); }
    if ("rcptHome" in d) { S.rcpt.open = null; S.rcpt.splitting = false; top(); return render(); }
    if (d.ract) return receiptAction(d.ract);
    if (d.ractGo) { const r = allReceipts().find((x) => x.receipt_id === S.rcpt.open); S.rcpt.done[r.receipt_id] = S.rcpt.pending; logAction(`${r.merchant}: ${S.rcpt.pending.toLowerCase()} (simulated)`); closeSheet(); render(); return toast(`${S.rcpt.pending}. Simulated in this preview.`); }
    if (d.bcat) { S.budget.cat = d.bcat; return render(); }
    if (d.swipe) { const top = $(".idea.top"); if (top) flyOut(top, d.swipe === "keep"); return; }
    if ("undo" in d) { const id = S.budget.history.pop(); if (id) { delete S.budget.accepted[id]; delete S.budget.exec[id]; S.budget.cat = budgetItems().find((x) => x.id === id).category; } return render(); }
    if (d.exec) return execSheet(d.exec);
    if (d.execGo) { const x = budgetItems().find((i) => i.id === d.execGo), e = execFor(x); S.budget.exec[x.id] = true; logAction(`${x.title}: ${e.done.toLowerCase()} (simulated)`); closeSheet(); render(); toast(`${e.done}. Simulated in this preview.`); return; }
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
  // Ambient texture: slow aurora gradients plus film grain, behind everything and non-interactive.
  function mountAura() {
    if ($("#aura")) return;
    const a = document.createElement("div"); a.id = "aura"; a.className = "aura"; a.setAttribute("aria-hidden", "true");
    a.innerHTML = "<i></i><i></i><i></i>";
    $("#phone").prepend(a);
  }
  async function boot() {
    mountAura();
    main.innerHTML = '<div class="empty" style="padding-top:120px">Loading your demo data…</div>';
    const urls = window.LANA_FIXTURE_URLS || ["fixtures/seed-v1.json", "../../fixtures/seed-v1.json"];
    for (const u of urls) {
      try { const r = await fetch(u, { cache: "no-store" }); if (r.ok) { DS = await r.json(); break; } } catch (_) {}
    }
    if (!DS) { main.innerHTML = '<div class="card" style="margin-top:40px"><span class="tag bad">Couldn’t load demo data</span><p class="small">Serve the repo root and open /preview/web/. See preview/README.md.</p></div>'; return; }
    S = initialState(); render(); renderChat();
  }
  boot();
})();
