import { createRequire } from 'node:module';
const { build } = createRequire(new URL('../../backend/package.json', import.meta.url))('esbuild');
import { writeFile, mkdir } from 'node:fs/promises';

const load = async entry => import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: [new URL(entry, import.meta.url).pathname], bundle: true, format: 'esm', write: false, logLevel: 'silent' })).outputFiles[0].text)}`);
const { scoreMarket, marketInstruments, basketSymbols } = await load('../../backend/src/market-pulse.ts');
const { inputsAt: computeInputs } = await load('../../backend/src/market-inputs.ts');
const memo = new Map();
const inputsAt = (all, t) => { if (!memo.has(t)) memo.set(t, computeInputs(all, t)); return memo.get(t); };

async function chart(symbol) {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=60d&interval=5m&includePrePost=true`;
  const r = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  if (!r.ok) throw new Error(`${symbol} ${r.status}`);
  const res = (await r.json()).chart.result[0];
  const q = res.indicators.quote[0], rows = [];
  res.timestamp.forEach((s, i) => { if (Number.isFinite(q.close[i])) rows.push({ t: s * 1000, open: q.open[i], close: q.close[i] }); });
  return rows;
}
const etFmt = ms => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(ms));
const etCache = new Map();
const et = ms => { let v = etCache.get(ms); if (v === undefined) { v = etFmt(ms); etCache.set(ms, v); } return v; };
const profiles = ['SPY', 'QQQ', 'XLE', 'DAL'];
const symbols = [...new Set([...marketInstruments.flatMap(i => i.kind === 'basket' ? [] : i.denominator ? [i.symbol, i.denominator] : [i.symbol]), ...basketSymbols, ...profiles])];
const raw = Object.fromEntries((await Promise.allSettled(symbols.map(async s => [s, await chart(s)]))).flatMap(r => r.status === 'fulfilled' ? [r.value] : (console.error('skipped', r.reason.message), [])));
const bars = Object.keys(raw).map(symbol => ({ symbol, times: raw[symbol].map(r => r.t), closes: raw[symbol].map(r => r.close), live: null }));
// Inputs added after the first backtest; "baseline" runs without them so the two sets are compared on identical days.
const added = new Set(['front_yield', 'real_yield', 'breadth', 'semis', 'vix_short']);
const variants = { baseline: new Set(added), 'with new inputs': new Set() };
let hidden = new Set();
const mask = list => list.map(x => hidden.has(x.id) ? { ...x, status: 'unavailable' } : x);

const sessionCache = new Map();
const session = (symbol, date) => { const key = symbol + date; if (!sessionCache.has(key)) sessionCache.set(key, computeSession(symbol, date)); return sessionCache.get(key); };
function computeSession(symbol, date) {
  const rows = raw[symbol].filter(r => { const s = et(r.t); return s.startsWith(date) && s.slice(12) >= '09:30' && s.slice(12) < '16:00'; });
  return rows.length > 60 ? { open: rows[0].open, close: rows.at(-1).close, rows } : null;
}
const priceAt = (rows, t) => rows.filter(r => r.t + 300000 <= t).at(-1)?.close;
const days = [...new Set(raw.SPY.map(r => et(r.t).slice(0, 10)))].filter(d => session('SPY', d));
const offset = d => { const probe = Date.parse(`${d}T13:25:00Z`); return et(probe).slice(12) === '09:25' ? 0 : 3600000; };

const corr = (x, y) => { const n = x.length, mx = x.reduce((a, b) => a + b) / n, my = y.reduce((a, b) => a + b) / n;
  let sxy = 0, sxx = 0, syy = 0; for (let i = 0; i < n; i++) { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) ** 2; syy += (y[i] - my) ** 2; } return sxx && syy ? sxy / Math.sqrt(sxx * syy) : 0; };
const allResults = {};
for (const [variant, drop] of Object.entries(variants)) {
  hidden = drop;
  const results = allResults[variant] = {};
// Only measure the move after the post-release capture baseline.
for (const withFutures of [true, false]) {
  for (const profile of profiles) {
    const rows = [];
    days.forEach((d, i) => {
      if (!i) return;
      const t = Date.parse(`${d}T12:35:00Z`) + offset(d), today = session(profile, d);
      const baseline = raw[profile].filter(r => r.t + 300000 <= t && t - (r.t + 300000) <= 300000).at(-1)?.close;
      if (!today || !(baseline > 0)) return;
      const inputs = mask(inputsAt(bars, t).map(x => !withFutures && x.id === 'futures' ? { ...x, status: 'unavailable' } : x)), scored = scoreMarket(inputs, profile);
      if (scored.status !== 'available') return;
      rows.push({ points: scored.points, ret: (today.open / baseline - 1) * 100, per: Object.fromEntries(scored.inputs.map(x => [x.id, x.points])) });
    });
    const x = rows.map(r => r.points), y = rows.map(r => r.ret), strong = rows.filter(r => Math.abs(r.points) >= 2);
    results[`8:35 → open (capture price → open) ${withFutures ? 'with' : 'without'} futures ${profile}`] = { days: rows.length, correlation: +corr(x, y).toFixed(3), strong_days: strong.length,
      hit_rate: strong.length ? +(strong.filter(r => Math.sign(r.points) === Math.sign(r.ret)).length / strong.length).toFixed(3) : null,
      per_input_correlation: Object.fromEntries(marketInstruments.map(i => [i.id, +corr(rows.map(r => r.per[i.id] ?? 0), y).toFixed(3)])) };
  }
}
for (const [label, hm] of [['pre-open 9:25 → close', '13:25'], ['midday 12:00 → close', '16:00']]) {
  for (const profile of profiles) {
    const rows = [];
    for (const d of days) {
      const t = Date.parse(`${d}T${hm}:00Z`) + offset(d);
      const s = session(profile, d); if (!s) continue;
      const inputs = mask(inputsAt(bars, t)), scored = scoreMarket(inputs, profile);
      if (scored.status !== 'available') continue;
      const start = hm === '13:25' ? s.open : priceAt(s.rows, t); if (!start) continue;
      rows.push({ d, points: scored.points, ret: (s.close / start - 1) * 100, per: Object.fromEntries(scored.inputs.map(i => [i.id, i.points])) });
    }
    const x = rows.map(r => r.points), y = rows.map(r => r.ret);
    const strong = rows.filter(r => Math.abs(r.points) >= 2);
    const hits = strong.filter(r => Math.sign(r.points) === Math.sign(r.ret)).length;
    const sorted = [...rows].sort((a, b) => a.points - b.points), third = Math.floor(rows.length / 3);
    const mean = a => a.length ? a.reduce((s, r) => s + r.ret, 0) / a.length : 0;
    results[`${label} ${profile}`] = { days: rows.length, correlation: +corr(x, y).toFixed(3), strong_days: strong.length, hit_rate: strong.length ? +(hits / strong.length).toFixed(3) : null,
      bottom_third_avg_return: +mean(sorted.slice(0, third)).toFixed(3), top_third_avg_return: +mean(sorted.slice(-third)).toFixed(3),
      per_input_correlation: Object.fromEntries(marketInstruments.map(i => [i.id, +corr(rows.map(r => r.per[i.id] ?? 0), y).toFixed(3)])) };
  }
}
}
await mkdir('.build-market-pulse', { recursive: true });
const out = { created_at: new Date().toISOString(), range: `${days[0]} to ${days.at(-1)}`, trading_days: days.length, results: allResults };
await writeFile('.build-market-pulse/backtest-market.json', JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 1));
