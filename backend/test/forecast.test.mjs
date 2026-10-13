import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { readFile } from 'node:fs/promises';

const forecastModule = await build({ absWorkingDir: new URL('..', import.meta.url).pathname, entryPoints: ['src/forecast.ts'], bundle: true, format: 'esm', write: false });
const modelModule = await build({ absWorkingDir: new URL('..', import.meta.url).pathname, entryPoints: ['src/forecast-model.ts'], bundle: true, format: 'esm', write: false });
const forecast = await import(`data:text/javascript,${encodeURIComponent(forecastModule.outputFiles[0].text)}`);
const model = await import(`data:text/javascript,${encodeURIComponent(modelModule.outputFiles[0].text)}`);
let mf, db;
const schema = await readFile(new URL('../migrations/0013_forecast_ledger.sql', import.meta.url), 'utf8');
before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true, script: 'export default { fetch() { return new Response() } }', compatibilityDate: '2026-09-06', d1Databases: ['DB'] }] }));
  db = await mf.getD1Database('DB');
  await db.batch(schema.split(';').filter(s => s.trim()).map(s => db.prepare(s)));
});
after(async () => { await mf?.dispose(); });
const pulse = { status: 'available', score: 62, research_score: 62, components: { news: { status: 'available', points: 5 }, market: { status: 'available', points: 3, live_inputs: 7 }, calendar: { points: 0 } }, coverage: { headline_stories: 4 } };
const snapshot = (created, asOf) => ({ created_at: created, as_of: asOf, pulse, inputs: { stories: [], impacts: [], market: [], calendar: [], prices: { SPY: { price: 100, price_at: asOf, source: 'https://query1.finance.yahoo.com/v8/finance/chart/SPY', previous_close: 99, previous_close_at: asOf.startsWith('2026-10-12') ? '2026-10-09T19:55:00Z' : '2026-10-12T19:55:00Z' }, QQQ: { price: 100, price_at: asOf, source: 'https://query1.finance.yahoo.com/v8/finance/chart/QQQ', previous_close: 99, previous_close_at: asOf.startsWith('2026-10-12') ? '2026-10-09T19:55:00Z' : '2026-10-12T19:55:00Z' } } }, model: { version: 'market-pulse-v2.1' } });
const barsArchive = () => {
  const times = ['2026-10-13T13:30:00Z'];
  return { retrieved_at: '2026-10-13T20:01:00Z', url: 'https://query1.finance.yahoo.com/v8/finance/chart/SPY', payload: { chart: { result: [{ timestamp: times.map(t => Date.parse(t) / 1000), indicators: { quote: [{ open: [101], close: [102] }] } }] } } };
};

test('saved research preserves evidence dates and opposing driver direction', async () => {
  const snap = snapshot('2026-10-14T12:36:00Z', '2026-10-14T12:35:00Z');
  snap.inputs.prices.QQQ.previous_close_at = '2026-10-13T19:55:00Z';
  const item = { title: 'Energy supply improves', source: 'Source', url: 'https://example.com/energy', received_at: '2026-10-14T10:31:00Z', published_at: '2026-10-14T10:30:00Z', direction: 1 };
  snap.pulse = { ...pulse, components: { ...pulse.components, news: { ...pulse.components.news, channels: [{ channel: 'energy', top: [item] }] } },
    drivers: [
      { kind: 'news', title: item.title, source: item.source, url: item.url, at: item.published_at, effect: 'higher', channel: 'energy' },
      { kind: 'news', title: 'Conflicting report', source: 'Source', url: 'https://example.com/conflict', at: '2026-10-14T10:40:00Z', effect: 'lower', detail: 'Supply risk' },
    ] };
  await forecast.captureForecast(db, { symbol: 'QQQ', snapshot: snap }, Date.parse('2026-10-14T12:37:00Z'));
  const research = await forecast.getResearch(db, 'QQQ');
  assert.equal(research.latest.evidence.length, 1);
  assert.equal(research.latest.evidence[0].received_at, item.received_at);
  assert.equal(research.latest.evidence[0].at, item.published_at);
  assert.equal(research.latest.contradictions.length, 1);
  assert.equal(research.latest.contradictions[0].at, '2026-10-14T10:40:00Z');
  assert.equal(research.latest.contradictions[0].reason, 'Supply risk');
  await db.prepare('DELETE FROM forecasts WHERE id=?').bind(research.latest.id).run();
});

test('NYSE sessions account for holidays, observed dates, DST and early closes', () => {
  assert.equal(forecast.sessionFor('2026-07-03'), null);
  assert.equal(forecast.sessionFor('2026-11-26'), null);
  assert.equal(new Date(forecast.sessionFor('2026-11-27').close).toISOString(), '2026-11-27T18:00:00.000Z');
  assert.equal(new Date(forecast.sessionFor('2026-10-13').open).toISOString(), '2026-10-13T13:30:00.000Z');
  assert.equal(new Date(forecast.sessionFor('2026-12-24').close).toISOString(), '2026-12-24T18:00:00.000Z');
  assert.equal(forecast.sessionFor('2021-12-31').open, Date.parse('2021-12-31T14:30:00Z'));
  assert.equal(new Date(forecast.sessionFor('2028-07-03').close).toISOString(), '2028-07-03T17:00:00.000Z');
  assert.equal(forecast.captureWindow(Date.parse('2026-10-12T14:00:00Z')).length, 0);
});

test('capture freezes all eligible horizons, ignores duplicate edits and rejects future evidence', async () => {
  const afterClose = snapshot('2026-10-12T19:51:00.000Z', '2026-10-12T19:50:00.000Z');
  const first = await forecast.captureForecast(db, { symbol: 'SPY', snapshot: afterClose }, Date.parse('2026-10-12T19:52:00Z'));
  assert.equal(first.forecasts.length, 1);
  assert.equal(first.forecasts[0].horizon, 'cutoff_to_open');
  const altered = snapshot('2026-10-12T19:52:00.000Z', '2026-10-12T19:50:00.000Z'); altered.pulse.score = 99;
  const duplicate = await forecast.captureForecast(db, { symbol: 'SPY', snapshot: altered }, Date.parse('2026-10-12T19:53:00Z'));
  assert.equal(duplicate.inserted, 0);
  assert.equal(duplicate.forecasts[0].score, first.forecasts[0].score);
  const frozen = await db.prepare('SELECT model_version,snapshot_json FROM forecasts WHERE id=?').bind(first.forecasts[0].id).first();
  assert.equal(frozen.model_version, 'forecast-adaptive-v2');
  assert.equal(JSON.parse(frozen.snapshot_json).learning.model, 'forecast-adaptive-v2');
  const preopen = await forecast.captureForecast(db, { symbol: 'QQQ', snapshot: snapshot('2026-10-13T12:36:00Z', '2026-10-13T12:35:00Z') }, Date.parse('2026-10-13T12:37:00Z'));
  assert.deepEqual(preopen.forecasts.map(r => r.horizon), ['opening_gap']);
  const openToClose = await forecast.captureForecast(db, { symbol: 'QQQ', snapshot: snapshot('2026-10-13T13:28:00Z', '2026-10-13T13:27:00Z') }, Date.parse('2026-10-13T13:29:00Z'));
  assert.deepEqual(openToClose.forecasts.map(r => r.horizon), ['open_to_close']);
  const leaky = snapshot('2026-10-13T12:36:00Z', '2026-10-13T12:35:00Z');
  leaky.inputs.stories.push({ published_at: '2026-10-13T12:35:01Z', received_at: '2026-10-13T12:35:01Z' });
  await assert.rejects(forecast.captureForecast(db, { symbol: 'QQQ', snapshot: leaky }, Date.parse('2026-10-13T12:37:00Z')), /after as_of/);
});

test('settlement requires matured timestamped source bars and writes immutable outcomes once', async () => {
  const archive = barsArchive();
  const early = await forecast.settleForecast(db, { symbol: 'SPY', prices: { SPY: archive } }, Date.parse('2026-10-13T20:02:00Z'));
  assert.equal(early.settled, 1);
  const again = await forecast.settleForecast(db, { symbol: 'SPY', prices: { SPY: archive } }, Date.parse('2026-10-13T20:03:00Z'));
  assert.equal(again.settled, 0);
  const research = await forecast.getResearch(db, 'SPY');
  assert.equal(research.performance.settled, 1);
  assert.equal(research.performance.probability_metrics, null);
  assert.equal(research.latest.probability_up, null);
  const row = await db.prepare("SELECT return_pct FROM forecast_outcomes WHERE forecast_id LIKE 'SPY_%'").first();
  assert.ok(row.return_pct > 0);
});

test('learning uses session-grouped chronological gaps and blocks weak support/calibration', () => {
  const rows = Array.from({ length: 400 }, (_, i) => ({ session_date: new Date(Date.UTC(2025, 0, 1 + i)).toISOString().slice(0,10), direction: i % 2 ? 1 : -1, features: { x: i % 2 ? 1 : -1 }, tilt: 'up' }));
  const split = model.chronologicalSplit(rows, r => r.session_date);
  const sessions = set => new Set(set.map(r => r.session_date));
  const a = sessions(split.train), b = sessions(split.calibration), c = sessions(split.test);
  assert.equal([...a].some(x => b.has(x) || c.has(x)), false);
  assert.equal([...b].some(x => c.has(x)), false);
  assert.ok(split.sessionCounts.gaps >= 10);
  const gate = model.promotionGate({ trainSessions: 20, calibrationSessions: 5, testSessions: 5, candidateBrier: 0.1, baselineBrier: 0.25, bins: [] });
  assert.equal(gate.eligible, false);
  assert.equal(gate.calibrated, false);
});

test('stale pulse scores do not become available forecast inputs', () => {
  const features = model.makeFeatures({ pulse: { status: 'stale', score: 82, research_score: 82, components: { news: { status: 'available', points: 4 }, market: { status: 'available', points: 2 } } } });
  assert.equal(features.score_available, 0);
  assert.equal(features.news_available, 0);
  assert.equal(model.forecastTilt(features).tilt, 'unavailable');
});

test('a news-noise candidate cannot promote when price-only features explain the outcome', () => {
  const rows = Array.from({ length: 400 }, (_, i) => {
    const market = i % 2 ? 0.6 : -0.6;
    return { outcome: market > 0 ? 1 : 0, features: { market_points: market, market_available: 1, market_coverage: 0.8,
      score_delta: Math.sin(i * 7) * 0.4, score_available: 1, news_points: Math.cos(i * 13) * 0.3, news_available: 1, calendar_points: 0, story_count: 0.2 } };
  });
  const full = model.trainLogistic(rows, Object.keys(rows[0].features), 0.2);
  const price = model.trainLogistic(rows, ['market_points', 'market_available', 'market_coverage'], 0.2);
  const candidateBrier = model.brierScore(rows.map(r => ({ probability: full.predict(r.features), outcome: r.outcome })));
  const priceOnlyBrier = model.brierScore(rows.map(r => ({ probability: price.predict(r.features), outcome: r.outcome })));
  const baselineBrier = model.brierScore(rows.map(r => ({ probability: 0.5, outcome: r.outcome })));
  const gate = model.promotionGate({ trainSessions: 240, calibrationSessions: 80, testSessions: 250, candidateBrier, baselineBrier, priceOnlyBrier,
    bins: model.calibrationBins(rows.map(r => ({ probability: full.predict(r.features), outcome: r.outcome }))) });
  assert.ok(candidateBrier <= baselineBrier - 0.01);
  assert.equal(gate.beatsBaseline, true);
  assert.equal(gate.beatsPriceOnly, false);
  assert.equal(gate.eligible, false);
});

test('candidate registration is scoped, immutable and receives only prospective predictions', async () => {
  const modelCoefficients = { intercept: 0, weights: { score_delta: 0.1 }, means: { score_delta: 0 }, scales: { score_delta: 1 } };
  const priceOnly = { coefficients: { intercept: 0, weights: { market_points: 0.05 }, means: { market_points: 0 }, scales: { market_points: 1 } }, calibrator: { slope: 1, intercept: 0 } };
  const registration = trainingHash => ({ symbol: 'SPY', horizon: 'cutoff_to_open', coefficients: modelCoefficients, priceOnly,
    calibrator: { slope: 1, intercept: 0 }, evaluation: { support: { train: 180, calibration: 60 } }, baselineUpProbability: 0.5,
    trainThrough: '2026-10-12', trainingHash });
  const candidate = await forecast.registerForecastCandidate(db, registration('a'.repeat(64)), Date.parse('2026-10-13T18:00:00Z'));
  const again = await forecast.registerForecastCandidate(db, registration('a'.repeat(64)), Date.parse('2026-10-13T18:01:00Z'));
  assert.equal(again.id, candidate.id);
  const snap = snapshot('2026-10-13T19:51:00Z', '2026-10-13T19:50:00Z');
  snap.inputs.prices.SPY.previous_close_at = '2026-10-12T19:55:00Z';
  snap.inputs.targets = snap.inputs.prices;
  const captured = await forecast.captureForecast(db, { symbol: 'SPY', snapshot: snap }, Date.parse('2026-10-13T19:52:00Z'));
  assert.equal(captured.forecasts.length, 1);
  const predictions = await db.prepare('SELECT probability_up,outcome FROM forecast_candidate_predictions WHERE candidate_id=?').bind(candidate.id).all();
  assert.equal(predictions.results.length, 1);
  assert.ok(predictions.results[0].probability_up > 0.5);
  assert.equal(predictions.results[0].outcome, null);
  const late = await forecast.registerForecastCandidate(db, registration('b'.repeat(64)), Date.parse('2026-10-13T19:52:30Z'));
  assert.notEqual(late.id, candidate.id);
  const duplicate = await forecast.captureForecast(db, { symbol: 'SPY', snapshot: snap }, Date.parse('2026-10-13T19:53:00Z'));
  assert.equal(duplicate.inserted, 0);
  const backdated = await db.prepare('SELECT COUNT(*) AS n FROM forecast_candidate_predictions WHERE candidate_id=?').bind(late.id).first();
  assert.equal(backdated.n, 0);
  const research = await forecast.getResearch(db, 'SPY');
  assert.equal(Object.hasOwn(research.latest, 'snapshot_json'), false);
  assert.equal(research.latest.probability_up, null);
});

test('post-release opening forecasts use capture prices and reject stale or future baselines', async () => {
  assert.equal(forecast.captureWindow(Date.parse('2026-10-15T11:05:00Z')).length, 0);
  assert.equal(forecast.captureWindow(Date.parse('2026-10-15T12:35:00Z'))[0].horizon, 'opening_gap');
  const snap = snapshot('2026-10-15T12:36:00Z', '2026-10-15T12:35:00Z');
  const quote = snap.inputs.prices.SPY;
  const now = Date.parse('2026-10-15T12:37:00Z');
  quote.price_at = '2026-10-15T12:29:00Z';
  await assert.rejects(forecast.captureForecast(db, { symbol: 'SPY', snapshot: snap }, now), /fresh frozen pre-market/);
  quote.price_at = '2026-10-15T12:36:00Z';
  await assert.rejects(forecast.captureForecast(db, { symbol: 'SPY', snapshot: snap }, now));
  quote.price_at = '2026-10-15T12:35:00Z';
  quote.previous_close = 50;
  const captured = await forecast.captureForecast(db, { symbol: 'SPY', snapshot: snap }, now);
  const row = await db.prepare('SELECT baseline_price,target_start_at FROM forecasts WHERE id=?').bind(captured.forecasts[0].id).first();
  assert.equal(row.baseline_price, 100);
  assert.equal(row.target_start_at, '2026-10-15T12:35:00.000Z');
  const archive = barsArchive();
  archive.retrieved_at = '2026-10-15T14:00:00Z';
  archive.payload.chart.result[0].timestamp = [Date.parse('2026-10-15T13:30:00Z') / 1000];
  const settled = await forecast.settleForecast(db, { symbol: 'SPY', prices: { SPY: archive } }, Date.parse('2026-10-15T14:01:00Z'));
  const outcome = settled.outcomes.find(o => o.forecast_id === captured.forecasts[0].id);
  assert.ok(Math.abs(outcome.return_pct - 1) < 1e-8);
  await db.prepare('UPDATE forecasts SET model_version=? WHERE id=?').bind('forecast-adaptive-v1', captured.forecasts[0].id).run();
  const training = await forecast.listForecastTrainingRows(db, 'SPY', 'opening_gap');
  assert.equal(training.rows.some(r => r.id === captured.forecasts[0].id), false);
  const research = await forecast.getResearch(db, 'SPY');
  assert.equal(research.performance.horizons.opening_gap.count, 0);
});
