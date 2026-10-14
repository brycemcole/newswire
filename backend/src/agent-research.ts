import { chartBars, findBar, nextSession, sessionFor } from './forecast';
import { researchSymbols, targetPrices } from './research-prices';
import { decodeEntities } from './research-discovery';

type DB = D1Database;
export class AgentResearchError extends Error {
  constructor(message: string, public readonly status = 400) { super(message); this.name = 'AgentResearchError'; }
}
const invalid = (message: string): never => { throw new AgentResearchError(message); };

export const agentHorizons = ['to_open', 'to_close', 'next_close'] as const;
type AgentHorizon = typeof agentHorizons[number];
type Window = { window: 'premarket' | 'late'; session_date: string; opens_at: string; closes_at: string; horizons: Array<{ horizon: AgentHorizon; target_session: string; target_end_at: string }> };

const minute = 60000;
const iso = (n: number) => new Date(n).toISOString();
const dateFmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' });
const verdicts = ['confirmed', 'contradicted', 'unresolved'];
const effects = ['lower', 'higher', 'none', 'unclear'];
const channels = ['energy', 'rates', 'trade', 'growth', 'credit', 'geopolitics', 'earnings'];

function text(value: unknown, field: string, max: number, required = true): string {
  const clean = typeof value === 'string' ? value.replace(/\s+/g, ' ').trim() : '';
  if (!clean && required) invalid(`${field} is required`);
  return clean.slice(0, max);
}
function sources(value: unknown) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 12) invalid('sources must be an array of at most 12 links');
  return (value as unknown[]).flatMap(raw => {
    const item = raw as Record<string, unknown>;
    try {
      const url = new URL(String(item?.url ?? ''));
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.href.length > 2000) return [];
      return [{ title: text(item.title, 'source title', 200, false) || url.hostname, url: url.href, ...(item.publisher ? { publisher: text(item.publisher, 'publisher', 80, false) } : {}) }];
    } catch { return []; }
  });
}
function count(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? Math.min(500, Math.max(0, Math.floor(n))) : 0;
}

/** Predictions are frozen only in two daily windows so every forecast is made before its target with a fresh server-observed price. */
export function predictionWindow(now = Date.now()): Window | null {
  const today = dateFmt.format(new Date(now)), session = sessionFor(today);
  if (!session) return null;
  const base = { session_date: today, opens_at: iso(session.open), closes_at: iso(session.close) };
  if (now >= session.open - 50 * minute && now < session.open - 5 * minute) {
    return { ...base, window: 'premarket', horizons: [
      { horizon: 'to_open', target_session: today, target_end_at: iso(session.open) },
      { horizon: 'to_close', target_session: today, target_end_at: iso(session.close) },
    ] };
  }
  if (now >= session.close - 30 * minute && now < session.close - 5 * minute) {
    const next = nextSession(today);
    return { ...base, window: 'late', horizons: [
      { horizon: 'to_open', target_session: next.date, target_end_at: iso(next.open) },
      { horizon: 'next_close', target_session: next.date, target_end_at: iso(next.close) },
    ] };
  }
  return null;
}

export async function recordAnswers(db: DB, input: unknown, now = Date.now()) {
  const body = input as Record<string, unknown>;
  if (!body || typeof body !== 'object' || !Array.isArray(body.answers) || !body.answers.length || body.answers.length > 20) invalid('Expected 1-20 answers');
  const model = text(body.model, 'model', 80), toolCalls = count(body.tool_calls);
  const stored: string[] = [];
  for (const raw of body.answers as unknown[]) {
    const item = raw as Record<string, unknown>;
    const id = text(item?.question_id, 'question_id', 160);
    const verdict = text(item.verdict, 'verdict', 20), effect = text(item.market_effect, 'market_effect', 20);
    if (!verdicts.includes(verdict)) invalid(`verdict must be one of ${verdicts.join(', ')}`);
    if (!effects.includes(effect)) invalid(`market_effect must be one of ${effects.join(', ')}`);
    const channel = item.channel === undefined || item.channel === null || item.channel === '' ? null : text(item.channel, 'channel', 20);
    if (channel && !channels.includes(channel)) invalid('Invalid channel');
    const confidence = Number(item.confidence);
    if (!(confidence >= 0 && confidence <= 1)) invalid('confidence must be 0-1');
    const exists = await db.prepare('SELECT id FROM research_questions WHERE id=?').bind(id).first();
    if (!exists) continue;
    await db.batch([
      db.prepare(`INSERT INTO research_answers (question_id,answered_at,question,verdict,answer,market_effect,channel,confidence,sources_json,model,tool_calls)
        VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(question_id) DO UPDATE SET answered_at=excluded.answered_at, question=excluded.question, verdict=excluded.verdict,
        answer=excluded.answer, market_effect=excluded.market_effect, channel=excluded.channel, confidence=excluded.confidence, sources_json=excluded.sources_json,
        model=excluded.model, tool_calls=excluded.tool_calls`)
        .bind(id, iso(now), text(item.question, 'question', 300), verdict, text(item.answer, 'answer', 1200), effect, channel, confidence, JSON.stringify(sources(item.sources)), model, toolCalls),
      db.prepare("UPDATE research_questions SET status='answered' WHERE id=? AND status IN ('open','queued','answered')").bind(id),
    ]);
    stored.push(id);
  }
  return { stored: stored.length, question_ids: stored };
}

export async function recordPredictions(db: DB, input: unknown, prices: any, now = Date.now()) {
  const body = input as Record<string, unknown>;
  if (!body || typeof body !== 'object' || !Array.isArray(body.predictions) || !body.predictions.length || body.predictions.length > 3) invalid('Expected 1-3 predictions');
  const symbol = text(body.symbol, 'symbol', 10).toUpperCase();
  if (!(researchSymbols as readonly string[]).includes(symbol)) invalid(`symbol must be one of ${researchSymbols.join(', ')}`);
  const window = predictionWindow(now);
  if (!window) return { inserted: 0, predictions: [], reason: 'Outside a prediction window' };
  const baseline = targetPrices(prices, now);
  if (!baseline.price || !baseline.price_at || now - Date.parse(baseline.price_at) > 15 * minute) throw new AgentResearchError('No completed price bar from the last 15 minutes', 503);
  const model = text(body.model, 'model', 80), toolCalls = count(body.tool_calls);
  const inserted: string[] = [];
  for (const raw of body.predictions as unknown[]) {
    const item = raw as Record<string, unknown>;
    const target = window.horizons.find(h => h.horizon === item?.horizon);
    if (!target) invalid(`horizon must be one of ${window.horizons.map(h => h.horizon).join(', ')} in the ${window.window} window`);
    const probability = Number(item.probability_up), move = Number(item.expected_move_pct);
    if (!(probability >= 0 && probability <= 1)) invalid('probability_up must be 0-1');
    if (!Number.isFinite(move) || Math.abs(move) > 10) invalid('expected_move_pct must be within ±10');
    const direction = probability > 0.5 ? 1 : probability < 0.5 ? -1 : 0;
    if (direction && move && Math.sign(move) !== direction) invalid('expected_move_pct must agree with probability_up');
    const drivers = Array.isArray(item.drivers) ? (item.drivers as unknown[]).slice(0, 6).map(d => text(d, 'driver', 200)).filter(Boolean) : [];
    const id = `${symbol}_${window.session_date}_${window.window}_${target!.horizon}`;
    const result = await db.prepare(`INSERT INTO agent_predictions (id,symbol,session_date,capture_window,horizon,made_at,target_session,target_end_at,baseline_price,baseline_at,baseline_source,
      probability_up,direction,expected_move_pct,rationale,drivers_json,sources_json,model,tool_calls) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING`)
      .bind(id, symbol, window.session_date, window.window, target!.horizon, iso(now), target!.target_session, target!.target_end_at, baseline.price, baseline.price_at, baseline.source,
        probability, direction, move, text(item.rationale, 'rationale', 800), JSON.stringify(drivers), JSON.stringify(sources(item.sources)), model, toolCalls).run();
    if (result.meta.changes) inserted.push(id);
  }
  return { inserted: inserted.length, predictions: inserted, window: window.window, baseline: { price: baseline.price, at: baseline.price_at } };
}

export async function pendingPredictionSymbols(db: DB, now = Date.now()): Promise<string[]> {
  const { results } = await db.prepare(`SELECT DISTINCT p.symbol FROM agent_predictions p LEFT JOIN agent_prediction_outcomes o ON o.prediction_id=p.id
    WHERE o.prediction_id IS NULL AND p.target_end_at<=?`).bind(iso(now)).all<{ symbol: string }>();
  return results.map(row => row.symbol).filter(s => (researchSymbols as readonly string[]).includes(s));
}

export async function settlePredictions(db: DB, prices: Record<string, any>, now = Date.now()) {
  const outcomes: Array<{ prediction_id: string; return_pct: number }> = [];
  for (const [symbol, archive] of Object.entries(prices)) {
    const retrieved = Date.parse(archive?.retrieved_at);
    const source = String(archive?.url ?? '');
    if (!Number.isFinite(retrieved) || !source.startsWith('https://') || !source.includes(`/chart/${symbol}`)) continue;
    const bars = chartBars(archive).filter(bar => bar.end <= retrieved);
    const { results } = await db.prepare(`SELECT p.* FROM agent_predictions p LEFT JOIN agent_prediction_outcomes o ON o.prediction_id=p.id
      WHERE p.symbol=? AND o.prediction_id IS NULL AND p.target_end_at<=? ORDER BY p.target_end_at LIMIT 200`).bind(symbol, iso(retrieved)).all<any>();
    for (const row of results) {
      const session = sessionFor(row.target_session);
      if (!session) continue;
      const bar = row.horizon === 'to_open' ? findBar(bars, session.open) : findBar(bars, session.close - 5 * minute);
      const price = row.horizon === 'to_open' ? bar?.open : bar?.close;
      if (!bar || !price || !(price > 0)) continue;
      const endAt = row.horizon === 'to_open' ? bar.start : bar.end;
      const pct = (price / row.baseline_price - 1) * 100, direction = Math.abs(pct) < 0.00005 ? 0 : pct > 0 ? 1 : -1;
      await db.prepare(`INSERT INTO agent_prediction_outcomes (prediction_id,endpoint_price,endpoint_at,return_pct,direction,source,source_retrieved_at,ingested_at)
        VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(prediction_id) DO NOTHING`).bind(row.id, price, iso(endAt), pct, direction, source, iso(retrieved), iso(now)).run();
      outcomes.push({ prediction_id: row.id, return_pct: pct });
    }
  }
  return { settled: outcomes.length, outcomes };
}

function performance(rows: any[]) {
  const settled = rows.filter(r => r.return_pct !== null && r.return_pct !== undefined);
  const moved = settled.filter(r => r.outcome_direction !== 0);
  const called = moved.filter(r => r.direction !== 0);
  const mean = (items: any[], f: (r: any) => number) => items.length ? items.reduce((s, r) => s + f(r), 0) / items.length : null;
  return { count: rows.length, settled: settled.length, scored: called.length,
    hit_rate: mean(called, r => r.direction === r.outcome_direction ? 1 : 0),
    always_up_hit_rate: mean(moved, r => r.outcome_direction > 0 ? 1 : 0),
    brier: mean(moved, r => (r.probability_up - (r.outcome_direction > 0 ? 1 : 0)) ** 2), coin_flip_brier: moved.length ? 0.25 : null,
    signal_return_pct: mean(called, r => r.direction * r.return_pct),
    move_error_pct: mean(settled, r => Math.abs(r.expected_move_pct - r.return_pct)) };
}

function predictionDTO(row: any) {
  return { id: row.id, symbol: row.symbol, window: row.capture_window, horizon: row.horizon, made_at: row.made_at, target_session: row.target_session, target_end_at: row.target_end_at,
    baseline_price: row.baseline_price, baseline_at: row.baseline_at, probability_up: row.probability_up, direction: row.direction, expected_move_pct: row.expected_move_pct,
    rationale: row.rationale, drivers: JSON.parse(row.drivers_json), sources: JSON.parse(row.sources_json), model: row.model,
    outcome: row.return_pct === null || row.return_pct === undefined ? null : { endpoint_price: row.endpoint_price, endpoint_at: row.endpoint_at, return_pct: row.return_pct, direction: row.outcome_direction, source: row.outcome_source } };
}

/** The most recent window's calls for every symbol, in a fixed symbol order. */
function board(rows: any[]) {
  const newest = new Map<string, string>();
  for (const row of rows) if (!newest.has(row.symbol)) newest.set(row.symbol, `${row.session_date}|${row.capture_window}`);
  return researchSymbols.filter(symbol => newest.has(symbol)).map(symbol => ({ symbol,
    predictions: rows.filter(row => row.symbol === symbol && `${row.session_date}|${row.capture_window}` === newest.get(symbol))
      .sort((a, b) => agentHorizons.indexOf(a.horizon) - agentHorizons.indexOf(b.horizon)).map(predictionDTO) }));
}

function questionGroups(rows: any[]) {
  const groups = new Map<string, any>();
  for (const row of rows) {
    const key = row.event_id ?? row.id;
    const answer = row.verdict ? { question: row.answer_question, verdict: row.verdict, answer: row.answer, market_effect: row.market_effect, channel: row.channel,
      confidence: row.confidence, sources: JSON.parse(row.sources_json ?? '[]'), answered_at: row.answered_at, model: row.model } : null;
    const group = groups.get(key);
    if (group) {
      group.question_ids.push(row.id);
      if (answer && (!group.answer || answer.answered_at > group.answer.answered_at)) group.answer = answer;
      if (row.status !== 'answered') group.status = 'open';
      continue;
    }
    groups.set(key, { id: row.id, question_ids: [row.id], query: row.query, reason: row.reason, status: row.status === 'answered' ? 'answered' : 'open', created_at: row.created_at,
      event_id: row.event_id ?? null, event: row.event_title ? { title: decodeEntities(row.event_title), url: row.event_url, source: row.event_source } : null, answer });
  }
  return [...groups.values()];
}

export async function getAgentResearch(db: DB, symbol: string, now = Date.now()) {
  if (!(researchSymbols as readonly string[]).includes(symbol)) invalid(`symbol must be one of ${researchSymbols.join(', ')}`);
  const window = predictionWindow(now);
  const [predictions, latest, questions] = await Promise.all([
    db.prepare(`SELECT p.*,o.endpoint_price,o.endpoint_at,o.return_pct,o.direction AS outcome_direction,o.source AS outcome_source FROM agent_predictions p
      LEFT JOIN agent_prediction_outcomes o ON o.prediction_id=p.id WHERE p.symbol=? ORDER BY p.made_at DESC, p.horizon LIMIT 400`).bind(symbol).all<any>(),
    db.prepare(`SELECT p.*,o.endpoint_price,o.endpoint_at,o.return_pct,o.direction AS outcome_direction,o.source AS outcome_source FROM agent_predictions p
      LEFT JOIN agent_prediction_outcomes o ON o.prediction_id=p.id WHERE p.made_at >= ? ORDER BY p.made_at DESC LIMIT 60`).bind(iso(now - 4 * 86400000)).all<any>(),
    db.prepare(`SELECT q.id,q.query,q.reason,q.status,q.created_at,q.event_id,i.title AS event_title,i.url AS event_url,i.source AS event_source,
      a.answered_at,a.question AS answer_question,a.verdict,a.answer,a.market_effect,a.channel,a.confidence,a.sources_json,a.model
      FROM research_questions q LEFT JOIN research_answers a ON a.question_id=q.id LEFT JOIN pulse_impacts i ON i.id=q.event_id
      WHERE q.status IN ('open','queued','answered') ORDER BY q.created_at DESC LIMIT 60`).all<any>(),
  ]);
  const rows = predictions.results;
  const made = new Set(rows.filter(r => window && r.session_date === window.session_date && r.capture_window === window.window).map(r => r.horizon));
  return { symbol, window: window ? { ...window, pending: window.horizons.filter(h => !made.has(h.horizon)).map(h => h.horizon) } : null,
    performance: { overall: performance(rows), horizons: Object.fromEntries(agentHorizons.map(h => [h, performance(rows.filter(r => r.horizon === h))])) },
    predictions: rows.slice(0, 30).map(predictionDTO), board: board(latest.results), questions: questionGroups(questions.results) };
}
