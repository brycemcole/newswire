import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const bundled = await build({ entryPoints: ['src/agent-research.ts'], bundle: true, format: 'esm', write: false });
const agent = await import(`data:text/javascript,${encodeURIComponent(bundled.outputFiles[0].text)}`);
const migrations = ['0012_pulse_impacts', '0013_forecast_ledger', '0015_research_discovery', '0017_research_agent'];
let mf, db;
before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true,
    script: 'export default { fetch() { return new Response() } }', compatibilityDate: '2026-09-06', d1Databases: ['DB'] }] }));
  db = await mf.getD1Database('DB');
  for (const name of migrations) {
    const sql = await readFile(new URL(`../migrations/${name}.sql`, import.meta.url), 'utf8');
    await db.batch(sql.split(';').filter(s => s.trim()).map(s => db.prepare(s)));
  }
});
after(async () => { await mf?.dispose(); });

const at = value => Date.parse(value);
function archive(symbol, bars, retrieved) {
  return { url: `https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?interval=5m`, retrieved_at: retrieved,
    payload: { chart: { result: [{ meta: { symbol }, timestamp: bars.map(b => at(b.start) / 1000),
      indicators: { quote: [{ open: bars.map(b => b.open ?? b.close), close: bars.map(b => b.close) }] } }] } } };
}

test('prediction windows open before the bell and late in the session only', () => {
  const premarket = agent.predictionWindow(at('2026-10-14T12:45:00Z'));
  assert.equal(premarket.window, 'premarket');
  assert.deepEqual(premarket.horizons.map(h => [h.horizon, h.target_session, h.target_end_at]), [
    ['to_open', '2026-10-14', '2026-10-14T13:30:00.000Z'], ['to_close', '2026-10-14', '2026-10-14T20:00:00.000Z']]);
  const late = agent.predictionWindow(at('2026-10-14T19:40:00Z'));
  assert.equal(late.window, 'late');
  assert.deepEqual(late.horizons.map(h => [h.horizon, h.target_session]), [['to_open', '2026-10-15'], ['next_close', '2026-10-15']]);
  assert.equal(agent.predictionWindow(at('2026-10-16T19:40:00Z')).horizons[0].target_session, '2026-10-19');
  assert.equal(agent.predictionWindow(at('2026-10-14T16:00:00Z')), null);
  assert.equal(agent.predictionWindow(at('2026-10-14T13:27:00Z')), null);
  assert.equal(agent.predictionWindow(at('2026-10-17T12:45:00Z')), null);
});

test('predictions freeze a server-observed baseline, reject inconsistent calls and settle against real session bars', async () => {
  const now = at('2026-10-14T12:45:00Z');
  const pre = archive('SPY', [{ start: '2026-10-14T12:35:00Z', close: 500 }], '2026-10-14T12:45:00Z');
  await assert.rejects(agent.recordPredictions(db, { symbol: 'SPY', model: 'deepseek-v4-pro', predictions: [
    { horizon: 'to_open', probability_up: 0.6, expected_move_pct: -0.2, rationale: 'Contradiction' }] }, pre, now), /agree/);
  await assert.rejects(agent.recordPredictions(db, { symbol: 'SPY', model: 'm', predictions: [{ horizon: 'next_close', probability_up: 0.6, expected_move_pct: 0.2, rationale: 'r' }] }, pre, now), /horizon/);
  const stale = archive('SPY', [{ start: '2026-10-14T11:00:00Z', close: 500 }], '2026-10-14T12:45:00Z');
  await assert.rejects(agent.recordPredictions(db, { symbol: 'SPY', model: 'm', predictions: [{ horizon: 'to_open', probability_up: 0.6, expected_move_pct: 0.2, rationale: 'r' }] }, stale, now), /15 minutes/);
  const body = { symbol: 'SPY', model: 'deepseek-v4-pro', tool_calls: 7, predictions: [
    { horizon: 'to_open', probability_up: 0.35, expected_move_pct: -0.3, rationale: 'Hot CPI and weaker futures.', drivers: ['CPI beat'], sources: [{ title: 'BLS', url: 'https://www.bls.gov/cpi/' }, { url: 'javascript:alert(1)' }] },
    { horizon: 'to_close', probability_up: 0.55, expected_move_pct: 0.2, rationale: 'Dip buying into earnings.' }] };
  const stored = await agent.recordPredictions(db, body, pre, now);
  assert.equal(stored.inserted, 2);
  assert.deepEqual(stored.baseline, { price: 500, at: '2026-10-14T12:40:00.000Z' });
  assert.equal((await agent.recordPredictions(db, { ...body, predictions: [{ ...body.predictions[0], probability_up: 0.9, expected_move_pct: 1 }] }, pre, now + 60000)).inserted, 0);
  assert.equal((await agent.recordPredictions(db, body, pre, at('2026-10-14T16:00:00Z'))).reason, 'Outside a prediction window');

  const settled = archive('SPY', [{ start: '2026-10-14T12:35:00Z', close: 500 }, { start: '2026-10-14T13:30:00Z', open: 497, close: 498 },
    { start: '2026-10-14T19:55:00Z', close: 505 }], '2026-10-14T20:10:00Z');
  assert.deepEqual(await agent.pendingPredictionSymbols(db, at('2026-10-14T20:10:00Z')), ['SPY']);
  const result = await agent.settlePredictions(db, { SPY: settled }, at('2026-10-14T20:10:00Z'));
  assert.equal(result.settled, 2);
  const view = await agent.getAgentResearch(db, 'SPY', at('2026-10-14T20:10:00Z'));
  const open = view.predictions.find(p => p.horizon === 'to_open'), close = view.predictions.find(p => p.horizon === 'to_close');
  assert.equal(open.outcome.endpoint_price, 497);
  assert.equal(open.outcome.endpoint_at, '2026-10-14T13:30:00.000Z');
  assert.equal(Math.round(open.outcome.return_pct * 100) / 100, -0.6);
  assert.equal(close.outcome.endpoint_at, '2026-10-14T20:00:00.000Z');
  assert.deepEqual(open.sources, [{ title: 'BLS', url: 'https://www.bls.gov/cpi/' }]);
  assert.equal(view.performance.overall.settled, 2);
  assert.equal(view.performance.overall.hit_rate, 1);
  assert.equal(view.performance.overall.always_up_hit_rate, 0.5);
  assert.ok(Math.abs(view.performance.overall.brier - (0.35 ** 2 + 0.45 ** 2) / 2) < 1e-9);
  assert.equal(view.window, null);
  assert.deepEqual(view.board.map(row => [row.symbol, row.predictions.map(p => p.horizon)]), [['SPY', ['to_open', 'to_close']]]);
});

test('answers resolve both halves of a confirm/contradict pair and show the original headline', async () => {
  await db.prepare(`INSERT INTO pulse_impacts (id,title,source,url,published_at,received_at,direction,channel,size,confidence,classified_at)
    VALUES ('abcdef0123456789','S&amp;P 500 posts its worst week since April','Reuters','https://reuters.example/spx','2026-10-14T10:00:00Z','2026-10-14T10:01:00Z',-1,'growth','moderate',0.8,'2026-10-14T10:02:00Z')`).run();
  for (const [id, role] of [['rd_confirm', 'confirm'], ['rd_contradict', 'contradict']]) {
    await db.prepare("INSERT INTO research_questions (id,query,reason,status,created_at,event_id) VALUES (?,?,?,'open','2026-10-14T11:00:00Z','abcdef0123456789')")
      .bind(id, `s p 500 worst week (${role})`, `${role} reason`).run();
  }
  let view = await agent.getAgentResearch(db, 'QQQ', at('2026-10-14T12:00:00Z'));
  assert.equal(view.questions.length, 1);
  assert.deepEqual(view.questions[0].question_ids.sort(), ['rd_confirm', 'rd_contradict']);
  assert.equal(view.questions[0].event.title, 'S&P 500 posts its worst week since April');
  assert.equal(view.questions[0].status, 'open');
  await assert.rejects(agent.recordAnswers(db, { model: 'm', answers: [{ question_id: 'rd_confirm', question: 'q', verdict: 'maybe', answer: 'a', market_effect: 'lower', confidence: 0.5 }] }), /verdict/);
  const answer = { question: 'Did the S&P 500 post its worst week since April?', verdict: 'confirmed', answer: 'Yes; it fell 3.1% for the week.', market_effect: 'lower', channel: 'growth', confidence: 0.8,
    sources: [{ title: 'Reuters', url: 'https://reuters.example/spx' }] };
  const stored = await agent.recordAnswers(db, { model: 'deepseek-v4.1-flash', tool_calls: 4, answers: [{ ...answer, question_id: 'rd_confirm' }, { ...answer, question_id: 'rd_contradict' }, { ...answer, question_id: 'missing' }] }, at('2026-10-14T12:05:00Z'));
  assert.equal(stored.stored, 2);
  view = await agent.getAgentResearch(db, 'QQQ', at('2026-10-14T12:10:00Z'));
  assert.equal(view.questions[0].status, 'answered');
  assert.equal(view.questions[0].answer.verdict, 'confirmed');
  assert.equal(view.questions[0].answer.question, answer.question);
  assert.deepEqual(view.questions[0].answer.sources, answer.sources);
});
