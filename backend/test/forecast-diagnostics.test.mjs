import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { readFile } from 'node:fs/promises';

const cwd = new URL('..', import.meta.url).pathname;
const load = async entry => import(`data:text/javascript,${encodeURIComponent((await build({ absWorkingDir: cwd, entryPoints: [entry], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const diag = await load('src/forecast-diagnostics.ts');
const forecast = await load('src/forecast.ts');
const model = await load('src/forecast-model.ts');
const adaptive = await load('src/adaptive-forecast.ts');

let seed = 7;
const random = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
const noise = () => (random() + random() + random() - 1.5) * 0.8;
const day = i => new Date(Date.UTC(2026, 0, 1 + i)).toISOString().slice(0, 10);
const makeRows = (count, edge = { news: 1, market: 0 }) => Array.from({ length: count }, (_, i) => {
  const news = random() * 2 - 1, market = random() * 2 - 1;
  const features = { score_available: 1, news_available: 1, market_available: 1, news_points: news, futures_points: market, rates_points: 0, volatility_points: 0, breadth_points: 0, overseas_points: 0, commodity_points: 0, market_other_points: 0, calendar_points: 0, earnings_points: 0, event_risk: 0 };
  const tilt = model.forecastTilt(features);
  const return_pct = edge.news * news * 0.6 + edge.market * market * 0.6 + noise();
  return { id: `f${i}`, session_date: day(i), horizon: 'open_to_close', forecast_at: `${day(i)}T13:25:00.000Z`, score: tilt.score, tilt: tilt.tilt,
    price_only_direction: Math.sign(market), return_pct, direction: Math.sign(return_pct), features };
});

test('default tilt parameters reproduce the original thresholds', () => {
  const f = { score_available: 1, news_points: 0.2, event_risk: 0 };
  assert.deepEqual(model.forecastTilt(f), model.forecastTilt(f, { eventShrink: 0.4, gain: 1, band: 5 }));
  assert.equal(model.forecastTilt({ ...f, news_points: 0.2 }).tilt, 'up');
  assert.equal(model.forecastTilt({ ...f, news_points: 0.2 }, { eventShrink: 0.4, gain: 1, band: 10 }).tilt, 'neutral');
  assert.equal(model.validTilt({ eventShrink: 0.4, gain: 1, band: 5 }), true);
  assert.equal(model.validTilt({ eventShrink: 2, gain: 1, band: 5 }), false);
});

test('term contributions sum to the score and trace a miss to the misleading term', () => {
  const [row] = makeRows(1);
  const points = diag.termContributions(row.features);
  assert.ok(Math.abs(50 + Object.values(points).reduce((a, b) => a + b, 0) - row.score) < 0.01);
  const shrunk = diag.termContributions({ ...row.features, event_risk: 1 });
  assert.ok(Math.abs(shrunk.news_points) <= Math.abs(points.news_points) * 0.61 + 1e-9);
});

test('miss report separates a helpful term from a harmful one', () => {
  const rows = makeRows(400, { news: 1, market: -1 });
  const report = diag.missReport(rows);
  const term = name => report.terms.find(t => t.term === name);
  assert.equal(term('news_points').verdict, 'helps');
  assert.equal(term('futures_points').verdict, 'hurts');
  assert.equal(term('calendar_points').verdict, 'insufficient');
  assert.ok(report.worst.length > 0 && report.worst.every(w => w.loss_pct > 0));
  assert.ok(report.worst[0].loss_pct >= report.worst.at(-1).loss_pct);
  assert.equal(report.overall.sessions, 400);
});

test('missing or zero outcomes are neither hits nor misses', () => {
  const rows = makeRows(60).map((r, i) => i % 2 ? { ...r, return_pct: 0, direction: 0 } : r);
  const report = diag.missReport(rows);
  assert.ok(report.overall.called <= 30);
  assert.deepEqual(diag.missReport([]).overall.hit_rate, null);
});

test('calibration map is monotone and withheld until enough sessions exist', () => {
  assert.equal(diag.calibrationMap(makeRows(20)).status, 'insufficient');
  const map = diag.calibrationMap(makeRows(500));
  assert.equal(map.status, 'ready');
  for (let i = 1; i < map.steps.length; i++) assert.ok(map.steps[i].p_up >= map.steps[i - 1].p_up);
  assert.ok(diag.applyCalibration(map, 95) >= diag.applyCalibration(map, 5));
  assert.equal(diag.applyCalibration({ status: 'insufficient', steps: [] }, 60), null);
});

test('walk-forward tuning proposes nothing when the defaults are already adequate and needs enough history', () => {
  assert.equal(diag.tuneTilt(makeRows(80)).status, 'insufficient');
  const result = diag.tuneTilt(makeRows(300, { news: 1, market: 0.3 }));
  assert.ok(['proposal', 'no_improvement'].includes(result.status));
  assert.ok(result.out_of_sample.sessions >= 60);
  if (result.status === 'proposal') assert.ok(result.out_of_sample.paired_t >= 1.28 && result.out_of_sample.mean_gain_pct >= 0.01);
});

test('walk-forward tuning never reads the session it scores', () => {
  const rows = makeRows(200, { news: 1, market: 0 });
  const tampered = rows.map((r, i) => i === 199 ? { ...r, return_pct: 1000 } : r);
  const a = diag.tuneTilt(rows), b = diag.tuneTilt(tampered);
  assert.notEqual(a.out_of_sample.current_mean_return_pct, b.out_of_sample.current_mean_return_pct);
  const leak = diag.tuneTilt(rows.slice(0, 199));
  assert.equal(leak.out_of_sample.sessions, a.out_of_sample.sessions - 1);
});

test('channel diagnostics find the half-life that matches the market and ignore future impacts', () => {
  const rows = makeRows(200, { news: 0, market: 0 });
  const impacts = [];
  rows.forEach((row, i) => {
    const direction = random() < 0.5 ? -1 : 1;
    const at = new Date(Date.parse(row.forecast_at) - 2 * 3600000).toISOString();
    impacts.push({ received_at: at, direction, channel: 'energy', size: 'major', confidence: 0.9 });
    row.return_pct = direction * 0.5 + noise() * 0.3; row.direction = Math.sign(row.return_pct);
    impacts.push({ received_at: new Date(Date.parse(row.forecast_at) + 3600000).toISOString(), direction: -direction, channel: 'energy', size: 'major', confidence: 0.9 });
  });
  const energy = diag.channelDiagnostics(rows, impacts).find(c => c.channel === 'energy');
  assert.ok(energy.current.correlation > 0.5);
  assert.equal(energy.recommendation, 'keep');
  assert.equal(diag.channelDiagnostics(rows, impacts).find(c => c.channel === 'rates').recommendation, 'insufficient');
  const inverted = diag.channelDiagnostics(rows.map(r => ({ ...r, return_pct: -r.return_pct, direction: -r.direction })), impacts).find(c => c.channel === 'energy');
  assert.equal(inverted.recommendation, 'invert_or_drop');
});

test('drift alerts fire once on a transition, not on every run', () => {
  const rows = makeRows(300, { news: 1, market: -1 });
  const report = diag.missReport(rows), channels = diag.channelDiagnostics(rows, []);
  const first = diag.driftAlerts(report, channels, null);
  assert.ok(first.some(a => a.kind === 'term_turned_harmful' && /futures_points/.test(a.detail)));
  assert.equal(diag.driftAlerts(report, channels, { terms: report.terms, channels }).filter(a => a.kind === 'term_turned_harmful').length, 0);
});

test('shadow parameter sets are promoted only after enough forward sessions and a real gain', () => {
  const mk = (n, gain) => Array.from({ length: n }, (_, i) => ({ session_date: day(i), return_pct: i % 2 ? 0.5 : -0.5, live_tilt: 'neutral', shadow_tilt: (i % 2 ? 1 : -1) * gain > 0 ? 'up' : 'down' }));
  assert.equal(diag.judgeParamSet(mk(30, 1)).status, 'shadow');
  const good = Array.from({ length: 80 }, (_, i) => ({ session_date: day(i), return_pct: (i % 2 ? 0.5 : -0.5) + (i % 3) * 0.01, live_tilt: 'neutral', shadow_tilt: i % 2 ? 'up' : 'down' }));
  assert.equal(diag.judgeParamSet(good).status, 'promoted');
  const bad = good.map(r => ({ ...r, shadow_tilt: r.shadow_tilt === 'up' ? 'down' : 'up' }));
  assert.equal(diag.judgeParamSet(bad).status, 'rejected');
});

let mf, db;
before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true, script: 'export default { fetch() { return new Response() } }', compatibilityDate: '2026-09-06', d1Databases: ['DB'] }] }));
  db = await mf.getD1Database('DB');
  for (const file of ['0013_forecast_ledger.sql', '0012_pulse_impacts.sql', '0021_learning_loop.sql'])
    await db.batch((await readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8')).split(';').filter(s => s.trim()).map(s => db.prepare(s)));
});
after(async () => { await mf?.dispose(); });

test('parameter sets register once, reject live duplicates, and promotion retires the previous set', async () => {
  const input = { symbol: 'SPY', horizon: 'open_to_close', params: { eventShrink: 0.2, gain: 1, band: 3.5 }, evaluation: { note: 'test' }, trainThrough: '2026-06-01' };
  const first = await forecast.registerParamSet(db, input);
  assert.equal(first.status, 'shadow');
  assert.equal((await forecast.registerParamSet(db, input)).duplicate, true);
  await assert.rejects(forecast.registerParamSet(db, { ...input, params: { eventShrink: 0.4, gain: 1, band: 5 } }), /equals the live/);
  await assert.rejects(forecast.registerParamSet(db, { ...input, params: { eventShrink: 5, gain: 1, band: 5 } }), /bounds/);
  for (let i = 0; i < 80; i++) {
    const id = `SPY_${day(i)}_open_to_close`, up = i % 2 === 0;
    await db.prepare(`INSERT INTO forecasts (id,symbol,session_date,horizon,forecast_at,target_start_at,target_end_at,model_version,input_version,score,tilt,features_json,snapshot_json,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(id, 'SPY', day(i), 'open_to_close', `${day(i)}T13:25:00Z`, `${day(i)}T13:30:00Z`, `${day(i)}T20:00:00Z`, 'forecast-adaptive-v2', 'x', 50, 'neutral', '{}', '{}', `${day(i)}T13:25:00Z`).run();
    await db.prepare('INSERT INTO forecast_outcomes (forecast_id,baseline_price,baseline_at,endpoint_price,endpoint_at,return_pct,direction,source,source_retrieved_at,ingested_at) VALUES (?,?,?,?,?,?,?,?,?,?)')
      .bind(id, 100, `${day(i)}T13:30:00Z`, 100, `${day(i)}T20:00:00Z`, (up ? 0.5 : -0.5) + (i % 7) * 0.02, up ? 1 : -1, 'https://query1.finance.yahoo.com/v8/finance/chart/SPY', `${day(i)}T20:05:00Z`, `${day(i)}T20:05:00Z`).run();
    await db.prepare('INSERT INTO forecast_param_predictions (forecast_id,param_set_id,score,tilt,predicted_at) VALUES (?,?,?,?,?)').bind(id, first.id, up ? 70 : 30, up ? 'up' : 'down', `${day(i)}T13:25:00Z`).run();
  }
  const evaluated = await forecast.evaluateParamSet(db, first.id);
  assert.equal(evaluated.status, 'promoted');
  assert.deepEqual((await adaptive.activeTiltParams(db, 'SPY')).open_to_close, { eventShrink: 0.2, gain: 1, band: 3.5 });
  assert.deepEqual(await adaptive.activeTiltParams(db, 'QQQ'), {});
  const second = await forecast.registerParamSet(db, { ...input, params: { eventShrink: 0.6, gain: 1.25, band: 5 }, trainThrough: '2026-07-01' });
  assert.equal(second.status, 'shadow');
  const data = await forecast.diagnosticsData(db, 'SPY', 'open_to_close');
  assert.equal(data.forecasts.length, 80);
  await forecast.saveLearningReport(db, { kind: 'weekly_diagnostics', symbol: 'SPY', horizon: 'open_to_close', window_end: '2026-04-01T00:00:00Z', report: { terms: [] } });
  assert.equal((await forecast.listLearningReports(db, 'weekly_diagnostics', 'SPY', 'open_to_close')).reports.length, 1);
});

const fixture = JSON.parse(await readFile(new URL('./fixtures/settled-forecasts.json', import.meta.url), 'utf8'));
const baseline = JSON.parse(await readFile(new URL('./fixtures/baseline-tilt.json', import.meta.url), 'utf8'));
const groups = [...new Set(fixture.map(row => `${row.symbol}|${row.horizon}`))];

test('backtest gate: the shipped model is not worse than the recorded baseline on every settled session so far', () => {
  assert.ok(fixture.length > 0 && groups.length > 0);
  for (const key of groups) {
    const [symbol, horizon] = key.split('|');
    const rows = fixture.filter(row => row.symbol === symbol && row.horizon === horizon).map(row => ({ ...row, score: null, tilt: 'x', price_only_direction: null }));
    const result = diag.backtestComparison(rows, model.defaultTilt, baseline);
    assert.ok(result.not_worse, `${key}: shipped parameters lose to the baseline (return ${result.baseline.mean_signed_return_pct} -> ${result.candidate.mean_signed_return_pct}, hit ${result.baseline.hit_rate} -> ${result.candidate.hit_rate}). Raise the bar only with a change that passes this test.`);
  }
});

test('backtest gate: a change that loses on history is detected, and tuning cannot propose it', () => {
  const rows = Array.from({ length: 120 }, (_, i) => {
    const strong = i % 2 === 0, news = (i % 4 < 2 ? 1 : -1) * (strong ? 0.9 : 0.3);
    const features = { score_available: 1, news_available: 1, news_points: news, event_risk: 0 };
    const return_pct = Math.sign(news) * (strong ? -0.3 : 0.6) + (i % 5) * 0.01;
    return { id: `d${i}`, session_date: day(i), horizon: 'open_to_close', forecast_at: `${day(i)}T13:25:00.000Z`, score: 50, tilt: 'x', price_only_direction: null, return_pct, direction: Math.sign(return_pct), features };
  });
  const worse = { eventShrink: 0.4, gain: 0.6, band: 10 };
  const loss = diag.backtestComparison(rows, worse, model.defaultTilt);
  assert.equal(loss.not_worse, false);
  assert.equal(diag.backtestComparison(rows, model.defaultTilt, model.defaultTilt).better, false);
  const tuned = diag.tuneTilt(rows);
  if (tuned.proposal) assert.ok(tuned.backtest.not_worse);
  const flipped = rows.map(r => ({ ...r, return_pct: -r.return_pct, direction: -r.direction }));
  assert.equal(diag.backtestComparison(flipped, { eventShrink: 0.4, gain: 1, band: 2 }, { eventShrink: 0.4, gain: 1, band: 9 }).better, false);
});

test('a parameter set that loses the full-history backtest cannot be promoted even with a good forward record', async () => {
  const input = { symbol: 'QQQ', horizon: 'open_to_close', params: { eventShrink: 0.8, gain: 0.5, band: 10 }, evaluation: {}, trainThrough: '2026-06-01' };
  const set = await forecast.registerParamSet(db, input);
  const features = JSON.stringify({ score_available: 1, news_available: 1, news_points: 0.4, event_risk: 0 });
  for (let i = 0; i < 80; i++) {
    const id = `QQQ_${day(i)}_open_to_close`, up = i % 2 === 0;
    await db.prepare(`INSERT INTO forecasts (id,symbol,session_date,horizon,forecast_at,target_start_at,target_end_at,model_version,input_version,score,tilt,features_json,snapshot_json,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(id, 'QQQ', day(i), 'open_to_close', `${day(i)}T13:25:00Z`, `${day(i)}T13:30:00Z`, `${day(i)}T20:00:00Z`, 'forecast-adaptive-v2', 'x', 60, 'up', features, '{}', `${day(i)}T13:25:00Z`).run();
    const ret = (up ? 0.5 : -0.5) + (i % 7) * 0.02;
    await db.prepare('INSERT INTO forecast_outcomes (forecast_id,baseline_price,baseline_at,endpoint_price,endpoint_at,return_pct,direction,source,source_retrieved_at,ingested_at) VALUES (?,?,?,?,?,?,?,?,?,?)')
      .bind(id, 100, `${day(i)}T13:30:00Z`, 100, `${day(i)}T20:00:00Z`, ret, up ? 1 : -1, 'https://query1.finance.yahoo.com/v8/finance/chart/QQQ', `${day(i)}T20:05:00Z`, `${day(i)}T20:05:00Z`).run();
    await db.prepare('INSERT INTO forecast_param_predictions (forecast_id,param_set_id,score,tilt,predicted_at) VALUES (?,?,?,?,?)').bind(id, set.id, up ? 70 : 30, up ? 'up' : 'down', `${day(i)}T13:25:00Z`).run();
  }
  const result = await forecast.evaluateParamSet(db, set.id);
  assert.equal(result.forward.backtest.not_worse, false);
  assert.equal(result.status, 'shadow');
});
