import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const module = await build({ entryPoints: ['src/adaptive-forecast.ts'], bundle: true, format: 'esm', write: false });
const { adaptiveForecast, adaptPulse } = await import(`data:text/javascript,${encodeURIComponent(module.outputFiles[0].text)}`);
const features = { score_available: 1, news_points: 0.3, market_points: 0.3, calendar_points: 0, earnings_points: 0 };
const asOf = '2026-10-13T18:00:00.000Z';
const rows = Array.from({ length: 80 }, (_, i) => {
  const day = new Date(Date.UTC(2026, 0, i + 1)).toISOString().slice(0, 10);
  return { id: String(i), session_date: day, horizon: 'open_to_close', forecast_at: `${day}T13:25:00.000Z`, available_at: `${day}T20:10:00.000Z`, direction: -1, return_pct: i % 2 ? -0.4 : -0.8, features };
});
const run = (data, f = features) => adaptiveForecast(f, data, 'open_to_close', asOf);
test('60 eligible sessions after 20 prior volatility observations gate learning', () => {
  assert.equal(run([]).status, 'collecting');
  assert.equal(run(rows.slice(0, 79)).training_sessions, 59);
  assert.equal(run(rows.slice(0, 79)).adjustment, 0);
  const learned = run(rows);
  assert.equal(learned.training_sessions, 60);
  assert.equal(learned.status, 'learning');
  assert.ok(learned.adjustment < 0);
  assert.ok(Math.abs(learned.adjustment) <= 12);
  assert.equal(learned.probability_up, null);
  assert.equal(Object.hasOwn(learned.weights, 'score_delta'), false);
});
test('future, duplicate and cross-horizon rows cannot change learned weights', () => {
  const extra = rows.map(r => ({ ...r, id: `other-${r.id}`, horizon: 'opening_gap', return_pct: 10 }));
  const future = rows.map(r => ({ ...r, id: `future-${r.id}`, available_at: '2027-01-01T00:00:00.000Z' }));
  assert.deepEqual(run([...rows, ...extra, ...future, ...rows]), run(rows));
  assert.equal(run(extra).settled, 0);
});
test('aggregate score delta cannot amplify correlated inputs', () => {
  assert.deepEqual(run(rows, { ...features, score_delta: 1000 }), run(rows, { ...features, score_delta: -1000 }));
  const learned = run(rows);
  assert.ok(Object.values(learned.weights).every(Number.isFinite));
  for (const key of ['futures_points', 'rates_points', 'volatility_points', 'overseas_points', 'commodity_points', 'market_other_points']) assert.ok(Number.isFinite(learned.weights[key]));
  const groups = ['futures_points', 'rates_points', 'volatility_points', 'overseas_points', 'commodity_points', 'market_other_points'].map(key => learned.weights[key]);
  assert.equal(learned.weights.market_points, Math.round(groups.reduce((s, v) => s + v, 0) / groups.length * 100) / 100);
});
test('targets preserve magnitude and volatility uses only outcomes known at each capture', () => {
  const small = rows.map(r => ({ ...r, return_pct: Number(r.id) < 20 ? r.return_pct : -0.001 }));
  assert.notDeepEqual(run(small).weights, run(rows).weights);
  const unavailableHistory = rows.map(r => ({ ...r, available_at: '2026-10-13T17:00:00.000Z' }));
  assert.equal(run(unavailableHistory).training_sessions, 0);
  assert.equal(run(rows.map(r => ({ ...r, return_pct: 0 }))).adjustment, 0);
});
test('collecting leaves the live score intact and stale evidence stays unavailable', () => {
  const pulse = { symbol: 'SPY', as_of: asOf, status: 'available', horizon: 'session', score: 73, research_score: 73, outlook: 'tailwinds', components: {} };
  assert.equal(adaptPulse(pulse, []).score, 73);
  assert.equal(adaptPulse({ ...pulse, status: 'stale', score: null }, rows).score, null);
  assert.equal(adaptPulse({ ...pulse, symbol: 'XLE' }, rows).learning, null);
});


test('warm-up reports checked predictions before weight training starts', () => {
  const learning = run(rows.slice(0, 4));
  assert.equal(learning.settled, 4);
  assert.equal(learning.training_sessions, 0);
  assert.match(learning.note, /4 saved predictions checked/);
  assert.match(learning.note, /warm-up: 4\/20/);
  assert.match(learning.note, /Predictions are active/);
});
test('learner separates market groups and only the predictive group gains weight', () => {
  const grouped = Array.from({ length: 80 }, (_, i) => {
    const day = new Date(Date.UTC(2026, 0, i + 1)).toISOString().slice(0, 10);
    const futures = i % 2 ? 0.1 : -0.1;
    return { id: String(i), session_date: day, horizon: 'open_to_close', forecast_at: `${day}T13:25:00.000Z`, available_at: `${day}T20:10:00.000Z`,
      direction: futures > 0 ? 1 : -1, return_pct: futures * (5 + (i % 5)), forecast_at_check: null,
      features: { score_available: 1, news_points: 0, calendar_points: 0, earnings_points: 0, futures_points: futures, commodity_points: Math.sin(i * 3) * 0.2,
        rates_points: 0, volatility_points: 0, overseas_points: 0, market_other_points: 0, market_points: futures } };
  });
  const learned = adaptiveForecast(grouped[0].features, grouped, 'open_to_close', asOf);
  assert.equal(learned.status, 'learning');
  assert.ok(learned.weights.futures_points > learned.weights.commodity_points);
  assert.ok(learned.weights.futures_points - 40 > Math.abs(learned.weights.commodity_points - 40));
});
