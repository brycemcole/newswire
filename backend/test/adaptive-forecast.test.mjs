import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const module = await build({ entryPoints: ['src/adaptive-forecast.ts'], bundle: true, format: 'esm', write: false });
const { adaptiveForecast, adaptPulse } = await import(`data:text/javascript,${encodeURIComponent(module.outputFiles[0].text)}`);
const features = { score_available: 1, market_available: 1, news_available: 1, score_delta: 0.5, news_points: 0.5, market_points: 0.5, calendar_points: 0 };
const asOf = '2026-10-13T18:00:00.000Z';
const outcome = (overrides = {}) => ({ id: 'one', session_date: '2026-10-12', horizon: 'open_to_close', available_at: '2026-10-12T20:10:00.000Z', direction: -1, features, ...overrides });

test('learning starts with the first settled forecast and never fabricates probabilities', () => {
  const base = adaptiveForecast(features, [], 'open_to_close', asOf);
  const learned = adaptiveForecast(features, [outcome()], 'open_to_close', asOf);
  assert.equal(base.status, 'starting');
  assert.equal(base.adjustment, 0);
  assert.equal(learned.status, 'learning');
  assert.equal(learned.settled, 1);
  assert.ok(learned.score < base.score);
  assert.ok(Math.abs(learned.adjustment) < 4);
  assert.equal(learned.probability_up, null);
});

test('future settlements and duplicate runs cannot add learning evidence', () => {
  const row = outcome();
  const future = outcome({ id: 'future', available_at: '2026-10-14T00:00:00.000Z' });
  const expected = adaptiveForecast(features, [row], 'open_to_close', asOf);
  assert.deepEqual(adaptiveForecast(features, [row, row, future], 'open_to_close', asOf), expected);
});

test('other periods have less influence and same-session forecasts do not multiply support', () => {
  const own = adaptiveForecast(features, [outcome()], 'open_to_close', asOf);
  const other = adaptiveForecast(features, [outcome({ horizon: 'opening_gap' })], 'open_to_close', asOf);
  assert.ok(Math.abs(other.adjustment) < Math.abs(own.adjustment));
  const rows = ['open_to_close', 'opening_gap', 'cutoff_to_open'].map((horizon, i) => outcome({ id: String(i), horizon }));
  const together = adaptiveForecast(features, rows, 'open_to_close', asOf);
  assert.equal(together.sessions, 1);
  assert.equal(together.same_horizon, 1);
  assert.ok(Math.abs(together.adjustment) <= Math.abs(own.adjustment));
});

test('recent misses outweigh old successes and live inputs can reverse the forecast', () => {
  const rows = Array.from({ length: 60 }, (_, i) => outcome({ id: String(i), session_date: new Date(Date.UTC(2026, 7, i + 1)).toISOString().slice(0, 10), direction: i < 40 ? 1 : -1 }));
  const learned = adaptiveForecast(features, rows, 'open_to_close', asOf);
  assert.ok(learned.adjustment < 0);
  assert.ok(Math.abs(learned.adjustment) <= 12);
  const reversed = { ...features, score_delta: -0.8, news_points: -0.8, market_points: -0.8 };
  assert.equal(adaptiveForecast(reversed, rows, 'open_to_close', asOf).tilt, 'down');
  assert.equal(adaptiveForecast({ ...features, score_delta: 0.8, news_points: 0.8, market_points: 0.8 }, rows, 'open_to_close', asOf).tilt, 'up');
});

test('learning never turns stale inputs into a current forecast', () => {
  const pulse = { symbol: 'SPY', as_of: asOf, status: 'stale', horizon: 'session', score: null, research_score: 80, outlook: 'unavailable', components: {} };
  assert.equal(adaptPulse(pulse, [outcome()]).score, null);
  assert.equal(adaptPulse({ ...pulse, symbol: 'XLE' }, [outcome()]).learning, null);
});
