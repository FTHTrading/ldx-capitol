/* LDX Capital PWA — credit engine, pipeline, copilot */
(function () {
  'use strict';

  /* ---------- Program credit box ---------- */
  const PROGRAMS = [
    {
      code: 'PERM', name: 'Permanent Financing',
      band: '$3M – $50M · Fixed 4.0% – 6.5%',
      ltv: 0.75, ltc: 0.80, dscrMin: 1.25, termMax: 30, purposes: ['Acquisition', 'Refinance'],
      channels: ['Traditional', 'Tokenized Pool']
    },
    {
      code: 'BRIDGE', name: 'Bridge Loan',
      band: '$2M – $50M · Float 6.0% – 12.0%',
      ltv: 0.85, ltc: 0.85, dscrMin: 1.10, termMax: 5, purposes: ['Acquisition', 'Recapitalization', 'Renovation / PIP', 'Bridge to Perm', 'Refinance'],
      channels: ['Traditional', 'Tokenized Pool']
    },
    {
      code: 'CONST', name: 'Construction Loan',
      band: '$2M – $50M · Float 7.0% – 12.0%',
      ltv: 0.80, ltc: 0.80, dscrMin: 1.20, termMax: 5, purposes: ['Construction / GC', 'Renovation / PIP'],
      channels: ['Traditional', 'Digital Escrow']
    },
    {
      code: 'MEZZ', name: 'Mezzanine / Pref Equity',
      band: '$1M – $10M · 12% – 20%',
      ltv: 0.85, ltc: 0.85, dscrMin: 1.05, termMax: 10, purposes: ['Acquisition', 'Recapitalization', 'Refinance'],
      channels: ['Traditional', 'Credit Facility']
    },
    {
      code: 'CPACE', name: 'C-PACE',
      band: '$1M – $50M · Fixed 6.0% – 8.0%',
      ltv: 0.25, ltc: 0.25, dscrMin: 0, termMax: 30, purposes: ['Construction / GC', 'Renovation / PIP', 'Recapitalization'],
      channels: ['Traditional', 'Tokenized Pool']
    },
    {
      code: 'SBA', name: 'SBA 7(a)',
      band: 'Up to $5M · Prime + 1.00–2.75%',
      ltv: 0.95, ltc: 0.95, dscrMin: 1.15, termMax: 25, purposes: ['Construction / GC', 'Renovation / PIP', 'Acquisition'],
      channels: ['Traditional', 'Guaranteed Strip']
    }
  ];

  /* ---------- Tabs ---------- */
  const tabs = document.querySelectorAll('.topbar nav button');
  tabs.forEach((b) => {
    b.addEventListener('click', () => {
      tabs.forEach((x) => x.classList.remove('active'));
      b.classList.add('active');
      document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
      document.getElementById('tab-' + b.dataset.tab).classList.add('active');
    });
  });

  /* ---------- PWA install prompt ---------- */
  let deferredPrompt = null;
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault(); deferredPrompt = e;
    const b = document.getElementById('installBtn'); b.hidden = false;
    b.addEventListener('click', async () => {
      b.hidden = true;
      deferredPrompt.prompt();
      await deferredPrompt.userChoice; deferredPrompt = null;
    }, { once: true });
  });

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }

  /* ---------- Deal evaluation ---------- */
  function readInputs() {
    return {
      propType: byId('propType').value,
      purpose: byId('purpose').value,
      value: num('value'),
      loan: num('loan'),
      noi: num('noi'),
      cost: num('cost'),
      nw: num('nw'),
      liq: num('liq'),
      term: num('term')
    };
  }
  function num(id) { return Number(document.getElementById(id).value) || 0; }
  function byId(id) { return document.getElementById(id); }
  function fmt(n) { return '$' + Math.round(n).toLocaleString('en-US'); }
  function pct(n) { return (n * 100).toFixed(1) + '%'; }

  function score(d, rateAssumption) {
    const ltv = d.value ? d.loan / d.value : 0;
    const ltc = d.cost ? d.loan / d.cost : 0;
    const rate = rateAssumption || 0.075;
    const amort = 30;
    const monthlyRate = rate / 12;
    const n = amort * 12;
    const monthly = (d.loan * monthlyRate) / (1 - Math.pow(1 + monthlyRate, -n));
    const annualDS = monthly * 12;
    const dscr = annualDS > 0 ? d.noi / annualDS : 0;

    return PROGRAMS.map((p) => {
      const gates = [];
      if (!p.purposes.includes(d.purpose)) gates.push('Purpose not eligible');
      if (ltv > p.ltv) gates.push('LTV exceeds ' + pct(p.ltv) + ' cap (deal: ' + pct(ltv) + ')');
      if (ltc > p.ltc) gates.push('LTC exceeds ' + pct(p.ltc) + ' cap (deal: ' + pct(ltc) + ')');
      if (p.dscrMin > 0 && dscr < p.dscrMin) gates.push('DSCR ' + dscr.toFixed(2) + 'x under floor of ' + p.dscrMin.toFixed(2) + 'x');
      if (d.term > p.termMax) gates.push('Requested term exceeds ' + p.termMax + ' yr cap');
      if (p.code === 'SBA' && d.loan > 5000000) gates.push('Loan exceeds $5M SBA ceiling');
      return { ...p, gates, ltv, ltc, dscr };
    });
  }

  function render(rows) {
    const box = byId('programs');
    box.innerHTML = '';
    const passing = rows.filter((r) => r.gates.length === 0);
    const failing = rows.filter((r) => r.gates.length > 0);

    const verdict = byId('verdict');
    if (passing.length === 0) {
      verdict.className = 'verdict fail';
      verdict.innerHTML = '<b>No clean fit.</b> Every program has at least one gate flag. Adjust loan size, structure, or program mix — the platform will re-price instantly.';
    } else {
      verdict.className = 'verdict pass';
      verdict.innerHTML = '<b>' + passing.length + ' program' + (passing.length > 1 ? 's' : '') + ' clear</b>. ' +
        passing.map((p) => p.name).join(', ') + '. LDX will price both execution channels for the top match.';
    }

    [...passing, ...failing].forEach((r) => {
      const row = document.createElement('div'); row.className = 'prow';
      const status = r.gates.length === 0 ? '<span class="badge pass">Clears</span>' :
        '<span class="badge fail">' + r.gates.length + ' flag' + (r.gates.length > 1 ? 's' : '') + '</span>';
      row.innerHTML =
        '<div class="pn">' + r.name + ' ' + status + '</div>' +
        '<div class="pt">' + r.band + '</div>' +
        '<div class="pt" style="margin-top:6px">LTV ' + pct(r.ltv) + ' · LTC ' + pct(r.ltc) + ' · DSCR ' + r.dscr.toFixed(2) + 'x</div>' +
        (r.gates.length ? '<div class="pt" style="margin-top:6px;color:#7a1e1e">' + r.gates.join(' · ') + '</div>' : '') +
        '<div class="badges">' + r.channels.map((c, i) => '<span class="badge channel-' + (i === 0 ? 't' : 'r') + '">' + c + '</span>').join('') + '</div>';
      box.appendChild(row);
    });
  }

  function stress(d) {
    const scenarios = [
      { name: 'Base case', noi: d.noi, rate: 0.075, value: d.value },
      { name: 'Income –10%', noi: d.noi * 0.9, rate: 0.075, value: d.value },
      { name: 'Rate +200 bps', noi: d.noi, rate: 0.095, value: d.value },
      { name: 'Value –15%', noi: d.noi, rate: 0.075, value: d.value * 0.85 }
    ];
    return scenarios.map((s) => {
      const monthlyRate = s.rate / 12;
      const monthly = (d.loan * monthlyRate) / (1 - Math.pow(1 + monthlyRate, -360));
      const ds = monthly * 12;
      const dscr = ds > 0 ? s.noi / ds : 0;
      const ltv = s.value ? d.loan / s.value : 0;
      let v = 'Pass';
      if (dscr < 1.10 || ltv > 0.85) v = 'Fail';
      else if (dscr < 1.25 || ltv > 0.75) v = 'Marginal';
      return { name: s.name, dscr, ltv, v };
    });
  }

  byId('runBtn').addEventListener('click', () => {
    render(score(readInputs()));
    byId('stress').hidden = true;
  });

  byId('stressBtn').addEventListener('click', () => {
    const d = readInputs();
    render(score(d));
    const rows = stress(d);
    byId('stressRows').innerHTML = rows.map((r) => {
      const cls = r.v === 'Pass' ? 'style="color:#0f5e40"' : r.v === 'Fail' ? 'style="color:#7a1e1e"' : 'style="color:#7a5f10"';
      return '<tr><td>' + r.name + '</td><td>' + r.dscr.toFixed(2) + 'x</td><td>' + (r.ltv * 100).toFixed(1) + '%</td><td ' + cls + '>' + r.v + '</td></tr>';
    }).join('');
    byId('stress').hidden = false;
  });

  /* ---------- Pipeline (localStorage) ---------- */
  const PIPE_KEY = 'ldx.pipeline';
  function pipeLoad() { try { return JSON.parse(localStorage.getItem(PIPE_KEY) || '[]'); } catch (e) { return []; } }
  function pipeSave(a) { localStorage.setItem(PIPE_KEY, JSON.stringify(a)); }

  byId('saveBtn').addEventListener('click', () => {
    const d = readInputs();
    const rows = score(d);
    const passing = rows.filter((r) => r.gates.length === 0);
    const entry = {
      id: Date.now(),
      when: new Date().toISOString(),
      propType: d.propType, purpose: d.purpose,
      loan: d.loan, value: d.value,
      topFit: passing[0] ? passing[0].name : 'No clean fit'
    };
    const list = pipeLoad(); list.unshift(entry); pipeSave(list); renderPipeline();
    byId('verdict').innerHTML = '<b>Saved to pipeline.</b> View under the Pipeline tab.';
    byId('verdict').className = 'verdict pass';
  });

  function renderPipeline() {
    const list = pipeLoad();
    byId('pipelineCount').textContent = list.length + ' deal' + (list.length === 1 ? '' : 's');
    const box = byId('pipelineList');
    box.innerHTML = list.length === 0
      ? '<div class="muted">No deals saved yet. Evaluate a deal and press <b>Save to Pipeline</b>.</div>'
      : list.map((e) =>
        '<div class="pcard"><div><div class="amt">' + fmt(e.loan) + '</div>' +
        '<div class="meta">' + e.propType + ' · ' + e.purpose + ' · fit: ' + e.topFit + '</div>' +
        '<div class="meta">' + new Date(e.when).toLocaleString() + '</div></div>' +
        '<button class="del" data-id="' + e.id + '">Remove</button></div>'
      ).join('');
    box.querySelectorAll('.del').forEach((b) => b.addEventListener('click', () => {
      pipeSave(pipeLoad().filter((x) => x.id !== Number(b.dataset.id)));
      renderPipeline();
    }));
  }
  byId('clearPipeline').addEventListener('click', () => { if (confirm('Clear all saved deals from this device?')) { pipeSave([]); renderPipeline(); } });
  renderPipeline();

  /* ---------- Copilot (rules-first, LLM later) ---------- */
  const KB = [
    { k: ['bridge', 'leverage', 'ltv'], a: 'Bridge program bands: LTV up to 85%, LTC up to 85%, DSCR floor 1.10x, term up to 5 years, interest-only, recourse. Every bridge is priced on both channels — traditional table funding or a Centrifuge-structured tokenized pool (senior/junior 75/25 representative split).' },
    { k: ['permanent', 'perm'], a: 'Permanent: $3M–$50M, fixed 4.0–6.5%, LTV 75% / LTC 80%, DSCR floor 1.25x, 10-yr term over 30-yr amort. Recourse and non-recourse options. Both channels available.' },
    { k: ['construction'], a: 'Construction: $2M–$50M, floating 7.0–12.0%, LTV 80% / LTC 80%, DSCR 1.20x stabilized, up to 5-yr term. Milestone-gated draws with inspection attestation; digital escrow variant releases from BitGo-custodied vaults on signed lien waiver.' },
    { k: ['cpace', 'c-pace', 'pace'], a: 'C-PACE: senior tax-assessment lien capped at 25% of value, up to 30 years fixed 6.0–8.0%, non-recourse. Best when there is qualifying scope (envelope, mechanicals, solar, water). Cheapest capital in the stack for energy-related work.' },
    { k: ['mezz', 'mezzanine', 'pref'], a: 'Mezz / Pref Equity: $1M–$10M, 12–20% coupon, combined LTV/LTC up to 85%, DSCR floor 1.05x on senior-plus-mezz stack. Recourse. Structured as custom tranches — clean fit for CMBS assumptions and sponsor buyouts.' },
    { k: ['sba', '7a', '7(a)'], a: 'SBA 7(a): up to $5M, Prime + 1.00–2.75%, LTV up to 95%, term up to 25 years, federal SBA guaranty. For owner-user commercial acquisition and construction; guaranteed strip is investor-transferable.' },
    { k: ['tokenized', 'pool', 'centrifuge'], a: 'Tokenized pools are structured on Centrifuge — the RWA protocol behind $1B+ in tokenized funds for managers like NYLIM. LDX loans get a senior share class sold to KYC-verified institutional investors and a junior first-loss retained by LDX. Senior yields typically 5–8% on a bridge or perm; junior sits at 20–30% of the stack. Same underwriting, faster capital.' },
    { k: ['bitgo', 'custody'], a: 'Every deal settles through segregated vaults at BitGo Bank & Trust, N.A. — a federally chartered, OCC-regulated national trust bank. 2-of-3 multi-sig, whitelisted destinations, dual approvals, velocity limits, and $250M in custodial insurance. No single party can move funds.' },
    { k: ['stress'], a: 'Every LDX deal runs a three-scenario stress suite: income –10%, rate +200 bps, value –15%. A deal must clear the base case and stay marginal-or-better in stress to price. Failure is the product — published discipline is why senior capital accepts sub-8% yields on this paper.' },
    { k: ['stablecoin', 'settlement'], a: 'Settlement stablecoin rails are in development on Unykorn\'s sovereign Rust ledger — deterministic, fully-reserved, issued through licensed partners for escrow, draws, and distributions. Not yet live for new closings; traditional and Centrifuge tokenized rails are both live today.' },
    { k: ['pace vs mezz', 'cpace vs mezz'], a: 'C-PACE wins when: (1) there is qualifying energy scope, (2) the borrower wants cheaper capital than 12–20% mezz, (3) non-recourse matters. Mezz wins when: (1) no PACE-eligible scope, (2) leverage is needed above senior + PACE combined, (3) speed matters — PACE assessments have municipal cadence that mezz does not.' },
    { k: ['fireblocks', 'anchorage'], a: 'BitGo Bank & Trust is our OCC-chartered custodian. Fireblocks and Anchorage are validated alternates for institutional counterparties that require them — either can be added to a deal\'s custody path without changing LDX pricing.' }
  ];

  function answer(q) {
    const lc = q.toLowerCase();
    let best = null, bestScore = 0;
    KB.forEach((e) => {
      let s = 0; e.k.forEach((k) => { if (lc.includes(k)) s += k.length; });
      if (s > bestScore) { bestScore = s; best = e; }
    });
    if (best && bestScore > 0) return best.a;
    return 'The demo copilot answers off a rules index — connect the API endpoint to swap in a live LLM. Try one of the suggested prompts, or ask about a specific program: permanent, bridge, construction, mezz, C-PACE, or SBA 7(a).';
  }

  function chatPush(text, who) {
    const log = byId('chatLog');
    const m = document.createElement('div'); m.className = 'msg ' + who; m.textContent = text;
    log.appendChild(m); log.scrollTop = log.scrollHeight;
  }

  byId('chatForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const input = byId('chatInput'); const q = input.value.trim(); if (!q) return;
    input.value = ''; chatPush(q, 'u');
    setTimeout(() => chatPush(answer(q), 'a'), 200);
  });

  document.querySelectorAll('.chip[data-q]').forEach((c) => c.addEventListener('click', () => {
    byId('chatInput').value = c.dataset.q;
    byId('chatForm').dispatchEvent(new Event('submit', { cancelable: true }));
  }));

  chatPush('Hi — I\'m the LDX credit copilot. Ask about our loan programs, stress methodology, tokenized pools, or the BitGo custody path. Enter a question below or tap a suggestion.', 'a');

  /* ---------- Account (localStorage) ---------- */
  const ACCT_KEY = 'ldx.acct';
  const loadAcct = () => { try { return JSON.parse(localStorage.getItem(ACCT_KEY) || '{}'); } catch (e) { return {}; } };
  const saveAcct = (o) => localStorage.setItem(ACCT_KEY, JSON.stringify(o));
  const acct = loadAcct();
  ['acctName', 'acctFirm', 'acctEmail', 'acctPhone'].forEach((k) => { const el = byId(k); if (acct[k]) el.value = acct[k]; });
  byId('saveAcct').addEventListener('click', () => {
    const o = {};
    ['acctName', 'acctFirm', 'acctEmail', 'acctPhone'].forEach((k) => o[k] = byId(k).value);
    saveAcct(o);
    alert('Saved to this device.');
  });
  byId('wipeAcct').addEventListener('click', () => {
    if (!confirm('Wipe all local data (account + pipeline)?')) return;
    localStorage.removeItem(ACCT_KEY); localStorage.removeItem(PIPE_KEY);
    ['acctName', 'acctFirm', 'acctEmail', 'acctPhone'].forEach((k) => byId(k).value = '');
    renderPipeline();
    alert('Cleared.');
  });
})();
