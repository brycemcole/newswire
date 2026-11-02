import { readFile, writeFile } from 'node:fs/promises';
import { loadModule } from './load-model.mjs';
import { token } from '../monitor/publish.mjs';

const { backtestComparison } = await loadModule('src/forecast-diagnostics.ts');
const { defaultTilt } = await loadModule('src/forecast-model.ts');
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const fixtureUrl = new URL('../../backend/test/fixtures/settled-forecasts.json', import.meta.url);
const baselineUrl = new URL('../../backend/test/fixtures/baseline-tilt.json', import.meta.url);
const symbols = ['SPY', 'QQQ'], horizons = ['opening_gap', 'cutoff_to_open', 'open_to_close'];

export async function fetchSettled() {
  const bearer = await token(), rows = [];
  for (const symbol of symbols) for (const horizon of horizons) {
    const response = await fetch(new URL(`/v1/research/training?${new URLSearchParams({ symbol, horizon })}`, origin), { headers: { Authorization: `Bearer ${bearer}` }, signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw new Error(`training ${symbol} ${horizon} HTTP ${response.status}`);
    for (const row of (await response.json()).rows ?? []) rows.push({ symbol, horizon, session_date: row.session_date, forecast_at: row.forecast_at, features: row.features, direction: row.direction, return_pct: row.return_pct });
  }
  return rows;
}

export function gate(rows, candidate = defaultTilt, baseline) {
  return symbols.flatMap(symbol => horizons.map(horizon => {
    const group = rows.filter(row => row.symbol === symbol && row.horizon === horizon).map(row => ({ ...row, score: null, tilt: 'x', price_only_direction: null }));
    return { symbol, horizon, ...backtestComparison(group, candidate, baseline) };
  }));
}

if (process.argv[1]?.endsWith('/backtest-gate.mjs')) {
  const args = process.argv.slice(2);
  if (args.includes('--export')) {
    const rows = await fetchSettled();
    await writeFile(fixtureUrl, JSON.stringify(rows) + '\n');
    console.log(`exported ${rows.length} settled sessions`);
  } else {
    const rows = args.includes('--live') ? await fetchSettled() : JSON.parse(await readFile(fixtureUrl, 'utf8'));
    const candidateArg = args.find(arg => arg.startsWith('--candidate='));
    const candidate = candidateArg ? JSON.parse(candidateArg.slice(12)) : defaultTilt;
    const baseline = JSON.parse(await readFile(baselineUrl, 'utf8'));
    const results = gate(rows, candidate, baseline);
    for (const r of results) console.log(`${r.symbol} ${r.horizon}: ${r.sessions} sessions${r.conclusive ? '' : ' (inconclusive)'}, return ${r.baseline.mean_signed_return_pct} -> ${r.candidate.mean_signed_return_pct}, hit ${r.baseline.hit_rate} -> ${r.candidate.hit_rate}, ${r.better ? 'better' : r.not_worse ? 'same' : 'WORSE'}`);
    if (results.some(r => !r.not_worse)) { console.error('Backtest gate failed: the candidate is worse than the baseline on settled history.'); process.exit(1); }
  }
}
