import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const { calculatePulse, loadPulse, loadPulseSnapshot } = await import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: ['src/market-pulse.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const { explain } = await import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: ['src/pulse-text.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const asOf = '2026-10-12T11:00:00Z';

function database(stories = [], impacts = []) {
  return { prepare(sql) {
    return { bind(...values) { this.values = values; return this; }, async all() {
      if (sql.includes('forecast_outcomes')) return { results: [] };
      if (sql.includes('pulse_impacts')) return { results: impacts.slice(0, Number(/LIMIT (\d+)/.exec(sql)?.[1] ?? impacts.length)) };
      return { results: stories };
    } };
  } };
}

const wireStory = { id: 'story-1', title: 'Missile attack hits Saudi oil facilities', summary: '', source: 'Publisher', url: 'https://example.com/story-1',
  published_at: '2026-10-12T10:00:00Z', received_at: '2026-10-12T10:01:00Z', retracted_at: null, tags: '["headlines"]', tickers: '[]' };
const impact = { id: 'impact-1', title: 'Unexpected energy supply disruption', source: 'Publisher', url: 'https://example.com/impact-1',
  published_at: '2026-10-12T10:00:00Z', received_at: '2026-10-12T10:01:00Z', direction: -1, channel: 'energy', size: 'major', confidence: 0.8,
  classified_at: '2026-10-12T10:02:00Z' };

test('live inputs reuse reads across symbols for two minutes, then see new stories', async t => {
  let now = Date.parse(asOf);
  t.mock.method(Date, 'now', () => now);
  const rows = [wireStory], db = database(rows, [impact]);
  let reads = 0;
  const prepare = db.prepare;
  db.prepare = sql => { reads += 1; return prepare(sql); };
  const first = await loadPulseSnapshot(db, new Date(now).toISOString(), 'SPY');
  now += 60000;
  rows.push({ ...wireStory, id: 'story-2' });
  const second = await loadPulseSnapshot(db, new Date(now).toISOString(), 'QQQ');
  assert.equal(reads, 2);
  assert.equal(second.inputs.stories.length, 1);
  assert.equal(second.as_of, first.as_of);
  assert.equal(second.pulse.symbol, 'QQQ');
  now += 60000;
  const fresh = await loadPulseSnapshot(db, new Date(now).toISOString());
  assert.equal(reads, 4);
  assert.equal(fresh.inputs.stories.length, 2);
  assert.notEqual(fresh.as_of, first.as_of);
  await loadPulseSnapshot(database(), new Date(now).toISOString());
  assert.equal((await loadPulseSnapshot(database(), new Date(now).toISOString())).inputs.stories.length, 0);
});

test('historical requests and different history windows never reuse live inputs', async t => {
  const now = Date.parse(asOf);
  t.mock.method(Date, 'now', () => now);
  const db = database([wireStory], [impact]);
  let reads = 0;
  const prepare = db.prepare;
  db.prepare = sql => { if (!sql.includes('forecast_outcomes')) reads += 1; return prepare(sql); };
  await loadPulseSnapshot(db, new Date(now).toISOString());
  await loadPulse(db, new Date(now).toISOString(), 'SPY', undefined, 12);
  assert.equal(reads, 4);
  await loadPulseSnapshot(db, new Date(now - 60000).toISOString());
  await loadPulseSnapshot(db, new Date(now - 60000).toISOString());
  assert.equal(reads, 8);
});

test('an unavailable impact store is retried instead of caching missing coverage', async t => {
  const now = Date.parse(asOf);
  t.mock.method(Date, 'now', () => now);
  const db = database([wireStory], [impact]), prepare = db.prepare;
  let fail = true;
  db.prepare = sql => {
    if (fail && sql.includes('pulse_impacts')) return { bind() { return this; }, async all() { throw new Error('Unavailable'); } };
    return prepare(sql);
  };
  assert.equal((await loadPulseSnapshot(db, asOf)).inputs.impacts.length, 0);
  fail = false;
  assert.equal((await loadPulseSnapshot(db, asOf)).inputs.impacts.length, 1);
});

test('late classifications enter an as-of score only once classified_at is reached', () => {
  const late = { ...impact, classified_at: '2026-10-12T11:00:01Z' };
  const before = calculatePulse([], asOf, 'SPY', false, { impacts: [late] });
  const after = calculatePulse([], '2026-10-12T11:00:02Z', 'SPY', false, { impacts: [late] });
  assert.equal(before.components.news.method, 'rules');
  assert.equal(before.components.news.status, 'no_coverage');
  assert.equal(after.components.news.method, 'jev');
  assert.equal(after.components.news.status, 'available');
});

test('historical loadPulse withholds unversioned actuals at its main as_of point', async () => {
  const event = { title: 'CPI m/m', at: '2026-10-12T10:00:00Z', forecast: '0.2%', actual: '0.4%', surprise: 0.2, threshold: 0.2 };
  const result = await loadPulse(database(), asOf, 'SPY', undefined, 0, [event]);
  assert.equal(result.components.calendar.points, 0);
  assert.equal(result.components.calendar.actuals_status, 'withheld_no_archived_vintage');
});

test('late impact classifications do not appear in earlier historical timeline points', async () => {
  const late = { ...impact, published_at: '2026-10-12T09:30:00Z', received_at: '2026-10-12T09:31:00Z', classified_at: '2026-10-12T10:45:00Z' };
  const result = await loadPulse(database([], [late]), asOf, 'SPY', undefined, 1);
  const before = result.history.find(point => point.as_of === '2026-10-12T10:30:00.000Z');
  const after = result.history.find(point => point.as_of === '2026-10-12T11:00:00.000Z');
  assert.equal(before.news_points, 0);
  assert.ok(after.news_points < 0);
});

test('snapshot preserves the full calculation inputs and the same explained live pulse', async () => {
  const market = [{ id: 'futures', label: 'S&P 500 futures', symbol: 'ES=F', unit: 'pct', price: 6000, price_at: asOf, change_day: 0.5, change_hour: 0.2, status: 'live' }];
  const calendar = [{ title: 'CPI m/m', at: '2026-10-12T10:00:00Z', forecast: '0.2%', actual: '0.4%', surprise: 0.2, threshold: 0.2 }];
  const stories = [{ ...wireStory, tags: JSON.parse(wireStory.tags), tickers: JSON.parse(wireStory.tickers) }];
  const db = database([wireStory], [impact]);
  const snapshot = await loadPulseSnapshot(db, asOf, 'SPY', market, calendar);
  const expected = calculatePulse(stories, asOf, 'SPY', false, { market, calendar, impacts: [impact] });
  assert.equal(snapshot.as_of, new Date(asOf).toISOString());
  assert.ok(Date.parse(snapshot.created_at));
  assert.deepEqual(snapshot.inputs, { stories, impacts: [impact], market, calendar });
  assert.deepEqual(snapshot.pulse, { ...expected, ...explain(expected) });
  assert.deepEqual(snapshot.model, { version: 'market-pulse-v2.2', windowHours: 96, halfLifeHours: 36, staleAfterHours: 24,
    factorPoints: { energy: 12, trade: 10, rates: 10, growth: 8, credit: 10 }, symbols: ['SPY', 'QQQ', 'XLE', 'DAL'],
    calibration: 'Uncalibrated research index; not a probability or expected return.' });
});

test('snapshot retains classified_at while withholding late rows from its as-of score', async () => {
  const late = { ...impact, classified_at: '2026-10-12T11:00:01Z' };
  const snapshot = await loadPulseSnapshot(database([], [late]), asOf);
  assert.deepEqual(snapshot.inputs.impacts, [late]);
  assert.equal(snapshot.pulse.components.news.method, 'rules');
  assert.equal(snapshot.pulse.components.news.classified, undefined);
});

test('impact query overflow marks the score incomplete instead of silently using a capped sample', async () => {
  const impacts = Array.from({ length: 5001 }, (_, i) => ({ ...impact, id: `impact-${i}` }));
  const snapshot = await loadPulseSnapshot(database([], impacts), asOf);
  assert.equal(snapshot.inputs.impacts.length, 5000);
  assert.equal(snapshot.pulse.coverage.impact_inputs_truncated, true);
  assert.equal(snapshot.pulse.status, 'incomplete');
  assert.equal(snapshot.pulse.score, null);
});

test('historical calendar scores withhold actuals without an archived vintage and label the gap', () => {
  const event = { title: 'CPI m/m', at: '2026-10-12T10:00:00Z', forecast: '0.2%', actual: '0.4%', surprise: 0.2, threshold: 0.2 };
  const historical = calculatePulse([], asOf, 'SPY', false, { calendar: [event], calendarRequiresVintage: true });
  const live = calculatePulse([], asOf, 'SPY', false, { calendar: [event] });
  assert.equal(historical.components.calendar.points, 0);
  assert.equal(historical.components.calendar.released.length, 0);
  assert.equal(historical.components.calendar.actuals_status, 'withheld_no_archived_vintage');
  assert.ok(historical.limitations.some(text => text.includes('no point-in-time vintage is archived')));
  assert.notEqual(live.components.calendar.points, 0);
});
