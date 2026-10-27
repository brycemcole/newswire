import { brierScore, calibrationBins, forecastModel, forecastTilt, makeFeatures, predictCandidate, promotionGate, type Horizon } from './forecast-model';
import { adaptiveForecast, adaptiveVersion, learningOutcomes } from './adaptive-forecast';

type DB = D1Database;
export class ForecastError extends Error {
  constructor(message: string, public readonly status = 400) { super(message); this.name = 'ForecastError'; }
}
const invalid = (message: string): never => { throw new ForecastError(message); };
type PriceBar = { start: number; end: number; open?: number; close?: number };
type Snapshot = { created_at: string; as_of: string; pulse: any; inputs: Record<string, unknown>; model: unknown };
type ForecastRow = { id: string; symbol: string; session_date: string; horizon: Horizon; forecast_at: string; target_start_at: string; target_end_at: string;
  model_version: string; input_version: string; score: number | null; baseline_price: number | null; baseline_at: string | null; price_only_direction: number | null; tilt: string; probabilities_json: string | null; features_json: string; snapshot_json: string; created_at: string };

const zone = 'America/New_York';
const dayMs = 86400000;
const dateFmt = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' });
const timeFmt = new Intl.DateTimeFormat('en-GB', { timeZone: zone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const partsFmt = new Intl.DateTimeFormat('en-US', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
const iso = (n: number) => new Date(n).toISOString();
const symbolOK = (s: string) => (forecastModel.symbols as readonly string[]).includes(s);
const validDate = (s: string) => /^\d{4}-\d\d-\d\d$/.test(s) && new Date(`${s}T00:00:00Z`).toISOString().slice(0, 10) === s;

function parts(timestamp: number) {
  return Object.fromEntries(partsFmt.formatToParts(new Date(timestamp)).map(p => [p.type, p.value]));
}
function nyAt(date: string, hour: number, minute: number) {
  const guess = Date.parse(`${date}T${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}:00Z`);
  const p = parts(guess);
  const represented = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  return guess + Date.UTC(+date.slice(0, 4), +date.slice(5, 7) - 1, +date.slice(8, 10), hour, minute) - represented;
}
function observed(date: string) {
  const d = new Date(`${date}T12:00:00Z`), w = d.getUTCDay();
  return new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
}
function easterSunday(year: number) {
  const a = year % 19, b = Math.floor(year / 100), c = year % 100, d = Math.floor(b / 4), e = b % 4, f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31), day = (h + l - 7 * m + 114) % 31 + 1;
  return new Date(Date.UTC(year, month - 1, day));
}
function nthWeekday(year: number, month: number, weekday: number, nth: number) {
  const first = new Date(Date.UTC(year, month - 1, 1)).getUTCDay();
  return new Date(Date.UTC(year, month - 1, 1 + (weekday - first + 7) % 7 + (nth - 1) * 7));
}
function lastWeekday(year: number, month: number, weekday: number) {
  const last = new Date(Date.UTC(year, month, 0)), back = (last.getUTCDay() - weekday + 7) % 7;
  return new Date(Date.UTC(year, month - 1, last.getUTCDate() - back));
}
function dateOf(d: Date) { return d.toISOString().slice(0, 10); }
function holidayDates(year: number) {
  const fixed = (m: number, d: number) => dateOf(new Date(Date.UTC(year, m - 1, d)));
  const observedFixed = (m: number, d: number) => {
    const dt = new Date(Date.UTC(year, m - 1, d));
    if (dt.getUTCDay() === 6) dt.setUTCDate(dt.getUTCDate() - 1);
    if (dt.getUTCDay() === 0) dt.setUTCDate(dt.getUTCDate() + 1);
    return dateOf(dt);
  };
  const thanksgiving = nthWeekday(year, 11, 4, 4);
  const goodFriday = easterSunday(year); goodFriday.setUTCDate(goodFriday.getUTCDate() - 2);
  const set = new Set([dateOf(nthWeekday(year, 1, 1, 3)), dateOf(nthWeekday(year, 2, 1, 3)), dateOf(goodFriday), dateOf(lastWeekday(year, 5, 1)),
    ...(year >= 2022 ? [observedFixed(6, 19)] : []), observedFixed(7, 4), dateOf(nthWeekday(year, 9, 1, 1)), dateOf(nthWeekday(year, 11, 4, 4)), observedFixed(12, 25)]);
  const newYear = new Date(Date.UTC(year, 0, 1));
  if (newYear.getUTCDay() === 0) set.add(`${year}-01-02`);
  else if (newYear.getUTCDay() !== 6) set.add(`${year}-01-01`);
  return { set, thanksgiving: dateOf(thanksgiving) };
}
export function sessionFor(date: string): { open: number; close: number } | null {
  if (!validDate(date)) return null;
  const weekday = new Date(`${date}T12:00:00Z`).getUTCDay();
  if (weekday === 0 || weekday === 6) return null;
  const { set, thanksgiving } = holidayDates(Number(date.slice(0, 4)));
  if (set.has(date)) return null;
  const d = new Date(`${date}T12:00:00Z`), dayBeforeThanksgiving = new Date(`${thanksgiving}T12:00:00Z`); dayBeforeThanksgiving.setUTCDate(dayBeforeThanksgiving.getUTCDate() + 1);
  const christmasEve = date.endsWith('-12-24');
  const early = dateOf(dayBeforeThanksgiving) === date || (christmasEve && weekday !== 0 && weekday !== 6) || (date.endsWith('-07-03') && weekday !== 0 && weekday !== 6);
  return { open: nyAt(date, 9, 30), close: nyAt(date, early ? 13 : 16, 0) };
}
export function nextSession(date: string) {
  let d = new Date(`${date}T12:00:00Z`);
  for (let i = 0; i < 12; i++) { d = new Date(+d + dayMs); const candidate = dateOf(d), session = sessionFor(candidate); if (session) return { date: candidate, ...session }; }
  throw new Error('Unable to resolve the next NYSE session');
}
function priorSession(date: string) {
  let d = new Date(`${date}T12:00:00Z`);
  for (let i = 0; i < 12; i++) { d = new Date(+d - dayMs); const candidate = dateOf(d), session = sessionFor(candidate); if (session) return { date: candidate, ...session }; }
  throw new Error('Unable to resolve the prior NYSE session');
}
function rowId(symbol: string, session: string, horizon: Horizon) { return `${symbol}_${session}_${horizon}`; }
function snapshotInputs(snapshot: Snapshot) {
  const created = Date.parse(snapshot.created_at), asOf = Date.parse(snapshot.as_of);
  if (!snapshot || !Number.isFinite(created) || !Number.isFinite(asOf) || asOf > created) invalid('Snapshot requires valid created_at and as_of timestamps');
  if (!snapshot.pulse || !snapshot.inputs || !snapshot.model) invalid('Snapshot must contain pulse, inputs and model');
  const inputs = snapshot.inputs as any;
  for (const story of inputs.stories ?? []) {
    const published = Date.parse(story.published_at), received = Date.parse(story.received_at);
    if (!Number.isFinite(published) || !Number.isFinite(received) || published > asOf || received > asOf) invalid('Snapshot contains story evidence from after as_of');
  }
  for (const impact of inputs.impacts ?? []) {
    const published = Date.parse(impact.published_at), received = Date.parse(impact.received_at);
    if (!Number.isFinite(published) || !Number.isFinite(received) || published > asOf || received > asOf) invalid('Snapshot contains impact evidence from after as_of');
  }
  for (const quote of inputs.market ?? []) {
    if (quote.price_at && (!Number.isFinite(Date.parse(quote.price_at)) || Date.parse(quote.price_at) > asOf)) invalid('Snapshot contains market evidence from after as_of');
  }
  for (const symbol of forecastModel.symbols) {
    const quote = inputs.targets?.[symbol] ?? inputs.prices?.[symbol];
    if (!quote) continue;
    const observed = Date.parse(quote.observed_at ?? quote.price_at ?? quote.at_cutoff?.at);
    const source = String(quote.source ?? quote.url ?? '');
    if (!Number.isFinite(observed) || observed > asOf || !source.startsWith('https://') || !source.includes('yahoo.com')) invalid('Frozen target price requires timestamped Yahoo source evidence before as_of');
    for (const field of ['price_at', 'previous_close_at']) if (quote[field] && (!Number.isFinite(Date.parse(quote[field])) || Date.parse(quote[field]) > asOf)) invalid('Frozen target price contains evidence from after as_of');
  }
  for (const event of inputs.calendar ?? []) {
    const at = Date.parse(event.at);
    if (!Number.isFinite(at) || (at > asOf && (event.actual !== null || event.surprise !== null))) invalid('Snapshot contains future calendar actuals');
  }
  return { created, asOf };
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
function stable(value: any): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
function evidenceQuestionCandidates(snapshot: Snapshot) {
  const candidates: Array<{ query: string; reason: string; event_id: string | null }> = [];
  for (const factor of snapshot.pulse?.factors ?? []) for (const item of factor.evidence ?? []) {
    if (!factor.conflicting && Number(item.confidence) >= 0.8 && !item.x) continue;
    const title = String(item.title ?? '').slice(0, 200);
    if (!title) continue;
    candidates.push({ query: `Was this report confirmed, and what broad-market evidence followed: “${title}”?`,
      reason: factor.conflicting ? `Conflicting evidence in the ${factor.factor} driver.` : `Unconfirmed evidence in the ${factor.factor} driver.`, event_id: item.story_id ?? null });
  }
  for (const channel of snapshot.pulse?.components?.news?.channels ?? []) for (const item of channel.top ?? []) {
    if (Number(item.confidence ?? 1) >= 0.8 && !item.x) continue;
    const title = String(item.title ?? '').slice(0, 200);
    if (title) candidates.push({ query: `Can this report be independently confirmed: “${title}”?`, reason: `Uncertain evidence in the ${channel.channel} channel.`, event_id: item.id ?? item.story_id ?? null });
  }
  for (const driver of snapshot.pulse?.drivers ?? []) if (driver.kind === 'news' && (Number(driver.confidence ?? 1) < 0.8 || driver.x)) {
    const title = String(driver.title ?? '').slice(0, 200);
    if (title) candidates.push({ query: `Can this report be independently confirmed: “${title}”?`, reason: 'Uncertain news driver.', event_id: driver.id ?? driver.story_id ?? null });
  }
  return [...new Map(candidates.map(item => [item.query, item])).values()].slice(0, 12);
}

export function captureWindow(now = Date.now()): { symbol: string; horizon: Horizon; session_date: string }[] {
  const local = parts(now), today = `${local.year}-${local.month}-${local.day}`, session = sessionFor(today);
  if (!session) return [];
  const minute = Number(local.hour) * 60 + Number(local.minute), close = timeFmt.format(new Date(session.close)).split(':').map(Number), closeMinute = close[0] * 60 + close[1];
  let horizon: Horizon | null = minute >= 515 && minute < 530 ? 'opening_gap' : minute >= 565 && minute < 570 ? 'open_to_close' : minute >= closeMinute - 15 && minute <= closeMinute ? 'cutoff_to_open' : null;
  if (!horizon) return [];
  const date = horizon === 'cutoff_to_open' ? nextSession(today).date : today;
  return forecastModel.symbols.map(symbol => ({ symbol, horizon: horizon!, session_date: date }));
}

export async function captureForecast(db: DB, input: { symbol: string; snapshot: Snapshot; targetSession?: string }, now = Date.now()) {
  const symbol = String(input.symbol ?? '').toUpperCase();
  if (!symbolOK(symbol)) invalid('symbol must be SPY or QQQ');
  const { created, asOf } = snapshotInputs(input.snapshot);
  if (created > now + 1000 || now - created > 20 * 60000 || asOf > now + 1000) invalid('Capture requires a fresh server snapshot');
  const local = parts(asOf), today = `${local.year}-${local.month}-${local.day}`;
  const sessionTimes = sessionFor(today);
  const currentSession = sessionTimes ? { date: today, ...sessionTimes } : null;
  const hhmm = Number(local.hour) * 60 + Number(local.minute);
  const closeParts = currentSession ? timeFmt.format(new Date(currentSession.close)).split(':').map(Number) : [0, 0];
  const closeMinute = closeParts[0] * 60 + closeParts[1];
  let horizon: Horizon | null = null, target = currentSession, baseline: { price: number; at: number } | null = null;
  if (currentSession && hhmm >= 515 && hhmm < 530) {
    horizon = 'opening_gap';
    target = currentSession;
    const quote = (input.snapshot.inputs as any).targets?.[symbol] ?? (input.snapshot.inputs as any).prices?.[symbol];
    const price = Number(quote?.price), at = Date.parse(quote?.price_at);
    const observed = quote?.observed_at === undefined ? asOf : Date.parse(quote.observed_at);
    if (!(price > 0) || !Number.isFinite(at) || at > asOf || asOf - at > 5 * 60000
      || !Number.isFinite(observed) || observed > asOf) invalid('Opening gap requires a fresh frozen pre-market target price at capture');
    baseline = { price, at };
  } else if (currentSession && hhmm >= 565 && hhmm < 570) {
    horizon = 'open_to_close';
    target = currentSession;
  } else if (currentSession && hhmm >= closeMinute - 15 && hhmm <= closeMinute) {
    horizon = 'cutoff_to_open';
    target = nextSession(today);
    const quote = (input.snapshot.inputs as any).targets?.[symbol] ?? (input.snapshot.inputs as any).prices?.[symbol];
    const price = Number(quote?.price ?? quote?.at_cutoff?.price), at = Date.parse(quote?.price_at ?? quote?.at_cutoff?.at);
    if (!(price > 0) || !Number.isFinite(at) || at > asOf || asOf - at > 15 * 60000 || (quote?.observed_at && Date.parse(quote.observed_at) > asOf)) invalid('Cutoff-to-open requires a fresh frozen target price in snapshot.inputs.targets');
    baseline = { price, at };
  }
  if (!horizon || !target) return { inserted: 0, forecasts: [] };
  if (input.targetSession && input.targetSession !== (horizon === 'cutoff_to_open' ? target.date : today)) invalid('targetSession does not match the session window');
  const features = makeFeatures(input.snapshot), createdAt = iso(now), forecastAt = iso(asOf);
  const forecast = adaptiveForecast(features, await learningOutcomes(db, symbol, forecastAt, horizon), horizon, forecastAt);
  const frozen = JSON.stringify({ ...input.snapshot, learning: forecast }), inputVersion = await sha256(stable({ ...input.snapshot.inputs, learning: forecast }));
  const marketPoints = Number((input.snapshot.pulse as any).components?.market?.points ?? 0);
  const priceOnlyDirection = marketPoints > 0 ? 1 : marketPoints < 0 ? -1 : 0;
  const start = horizon === 'opening_gap' ? baseline!.at : horizon === 'cutoff_to_open' ? baseline!.at : target.open;
  const end = horizon === 'open_to_close' ? target.close : target.open + 5 * 60000;
  const row: ForecastRow = { id: rowId(symbol, target.date, horizon), symbol, session_date: target.date, horizon, forecast_at: forecastAt,
    target_start_at: iso(start), target_end_at: iso(end), model_version: adaptiveVersion, input_version: inputVersion, score: forecast.score,
    baseline_price: baseline?.price ?? null, baseline_at: baseline ? iso(baseline.at) : null, price_only_direction: priceOnlyDirection,
    tilt: forecast.tilt, probabilities_json: null, features_json: JSON.stringify(features), snapshot_json: frozen, created_at: createdAt };
  const insertion = await db.prepare(`INSERT INTO forecasts (id,symbol,session_date,horizon,forecast_at,target_start_at,target_end_at,model_version,input_version,score,baseline_price,baseline_at,price_only_direction,tilt,probabilities_json,features_json,snapshot_json,created_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(symbol,session_date,horizon) DO NOTHING`).bind(row.id,row.symbol,row.session_date,row.horizon,row.forecast_at,row.target_start_at,row.target_end_at,row.model_version,row.input_version,row.score,row.baseline_price,row.baseline_at,row.price_only_direction,row.tilt,row.probabilities_json,row.features_json,row.snapshot_json,row.created_at).run();
  if (insertion.meta.changes > 0) {
    const candidates = await db.prepare("SELECT id,coefficients_json,status FROM forecast_models WHERE symbol=? AND horizon=? AND model_version='ridge-logit-shadow-v2' AND status IN ('shadow','promoted') ORDER BY created_at DESC LIMIT 10").bind(symbol,horizon).all<any>();
    for (const candidate of candidates.results) {
    const saved = JSON.parse(candidate.coefficients_json), probability = predictCandidate(saved, features);
    const priceOnlyProbability = predictCandidate(saved.priceOnly, features);
    if (probability === null || priceOnlyProbability === null) continue;
    await db.prepare('INSERT INTO forecast_candidate_predictions (forecast_id,candidate_id,probability_up,price_only_probability_up,predicted_at) VALUES (?,?,?,?,?) ON CONFLICT(forecast_id,candidate_id) DO NOTHING')
      .bind(row.id,candidate.id,probability,priceOnlyProbability,forecastAt).run();
    }
  }
  for (const question of evidenceQuestionCandidates(input.snapshot)) {
    const id = `rq_${(await sha256(`${symbol}|${target.date}|${question.event_id}|${question.query}`)).slice(0, 30)}`;
    await db.prepare("INSERT INTO research_questions (id,query,reason,status,created_at,event_id) VALUES (?,?,?,'open',?,?) ON CONFLICT(id) DO NOTHING").bind(id,question.query,question.reason,createdAt,question.event_id).run();
  }
  const result = await db.prepare('SELECT id,symbol,session_date,horizon,forecast_at,target_start_at,target_end_at,model_version,input_version,score,tilt,created_at FROM forecasts WHERE id=?').bind(row.id).first<any>();
  return { inserted: insertion.meta.changes > 0 ? 1 : 0, forecasts: result ? [result] : [] };
}

export function chartBars(value: any): PriceBar[] {
  const chart = value?.payload?.chart?.result?.[0];
  if (!chart || !Array.isArray(chart.timestamp)) return [];
  const q = chart.indicators?.quote?.[0] ?? {};
  return chart.timestamp.map((stamp: number, i: number) => ({ start: stamp * 1000, end: (stamp + 300) * 1000, open: q.open?.[i], close: q.close?.[i] }))
    .filter((b: PriceBar) => Number.isFinite(b.start) && Number.isFinite(b.close) && Number(b.close) > 0).sort((a: PriceBar,b: PriceBar) => a.start - b.start);
}
export function findBar(bars: PriceBar[], at: number) { return bars.find(b => b.start === at); }
function resultPrice(row: ForecastRow, bars: PriceBar[], retrieved: number) {
  const end = Date.parse(row.target_end_at);
  if (retrieved < end) return null;
  const targetDate = dateFmt.format(new Date(end - 1));
  const openAt = sessionFor(targetDate)?.open;
  const closeAt = sessionFor(targetDate)?.close;
  if (row.horizon === 'opening_gap') {
    const endpoint = openAt === undefined ? undefined : findBar(bars, openAt);
    return row.baseline_price && row.baseline_at && endpoint?.open ? { base: row.baseline_price, baseAt: Date.parse(row.baseline_at), end: endpoint.open, endAt: endpoint.start } : null;
  }
  if (row.horizon === 'open_to_close') {
    const base = openAt === undefined ? undefined : findBar(bars, openAt);
    const endpoint = closeAt === undefined ? undefined : findBar(bars, closeAt - 300000);
    return base?.open && endpoint?.close ? { base: base.open, baseAt: base.start, end: endpoint.close, endAt: endpoint.end } : null;
  }
  const endpoint = openAt === undefined ? undefined : findBar(bars, openAt);
  return row.baseline_price && row.baseline_at && endpoint?.open ? { base: row.baseline_price, baseAt: Date.parse(row.baseline_at), end: endpoint.open, endAt: endpoint.start } : null;
}

export async function pendingSettlementSymbols(db: DB, now = Date.now()): Promise<string[]> {
  const { results } = await db.prepare(`SELECT DISTINCT f.symbol FROM forecasts f LEFT JOIN forecast_outcomes o ON o.forecast_id=f.id
    WHERE o.forecast_id IS NULL AND f.target_end_at<=? ORDER BY f.symbol`).bind(iso(now)).all<{ symbol: string }>();
  return results.map(row => row.symbol).filter(symbolOK);
}

export async function settleForecast(db: DB, input: { symbol?: string; prices: Record<string, any>; retrievedAt?: string }, now = Date.now()) {
  const symbols = input.symbol ? [String(input.symbol).toUpperCase()] : [...forecastModel.symbols];
  if (symbols.some(s => !symbolOK(s))) invalid('symbol must be SPY or QQQ');
  const outcomes: Array<{ forecast_id: string; return_pct: number; direction: number }> = [];
  for (const symbol of symbols) {
    const archive = input.prices?.[symbol];
    if (!archive || archive.error) continue;
    const retrievedAt = input.retrievedAt ?? archive?.retrieved_at;
    const retrieved = Date.parse(retrievedAt);
    if (!Number.isFinite(retrieved) || retrieved > now + 1000 || !(typeof (archive?.url ?? archive?.source) === 'string' && /^https:\/\//.test(archive.url ?? archive.source))) invalid('Settlement requires timestamped HTTPS source provenance');
    const sourceUrl = String(archive.url ?? archive.source);
    if (!(new URL(sourceUrl).hostname === 'yahoo.com' || new URL(sourceUrl).hostname.endsWith('.yahoo.com')) || !sourceUrl.includes(`/chart/${symbol}`)) invalid('Settlement source must be Yahoo chart data for the requested symbol');
    const bars = chartBars(archive).filter(bar => bar.end <= retrieved);
    if (!bars.length) continue;
    const { results } = await db.prepare(`SELECT f.* FROM forecasts f LEFT JOIN forecast_outcomes o ON o.forecast_id=f.id
      WHERE f.symbol=? AND o.forecast_id IS NULL AND f.target_end_at<=? ORDER BY f.target_end_at LIMIT 250`).bind(symbol, iso(retrieved)).all<ForecastRow>();
    for (const row of results) {
      const prices = resultPrice(row, bars, retrieved);
      if (!prices || !(prices.base > 0) || !(prices.end > 0) || prices.endAt < prices.baseAt) continue;
      const pct = (prices.end / prices.base - 1) * 100, direction = Math.abs(pct) < 0.00005 ? 0 : pct > 0 ? 1 : -1;
      await db.prepare(`INSERT INTO forecast_outcomes (forecast_id,baseline_price,baseline_at,endpoint_price,endpoint_at,return_pct,direction,source,source_retrieved_at,ingested_at)
        VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(forecast_id) DO NOTHING`).bind(row.id,prices.base,iso(prices.baseAt),prices.end,iso(prices.endAt),pct,direction,String(archive.url ?? archive.source),iso(retrieved),iso(now)).run();
      if (direction !== 0) await db.prepare('UPDATE forecast_candidate_predictions SET outcome=? WHERE forecast_id=? AND outcome IS NULL').bind(direction > 0 ? 1 : 0,row.id).run();
      outcomes.push({ forecast_id: row.id, return_pct: pct, direction });
    }
  }
  return { settled: outcomes.length, outcomes };
}

export async function listForecastTrainingRows(db: DB, symbol: string, horizon: Horizon) {
  symbol = String(symbol ?? '').toUpperCase();
  if (!symbolOK(symbol) || !(forecastModel.horizons as readonly string[]).includes(horizon)) invalid('symbol and horizon are invalid');
  const { results } = await db.prepare(`SELECT f.id,f.symbol,f.session_date,f.horizon,f.forecast_at,f.tilt,f.features_json,o.direction,o.return_pct
    FROM forecasts f JOIN forecast_outcomes o ON o.forecast_id=f.id WHERE f.symbol=? AND f.horizon=? AND f.model_version=? ORDER BY f.session_date,f.forecast_at`).bind(symbol,horizon,adaptiveVersion).all<any>();
  return { symbol, horizon, rows: results.map(row => ({ ...row, features: JSON.parse(row.features_json) })) };
}

export async function registerForecastCandidate(db: DB, input: { symbol: string; horizon: Horizon; coefficients: unknown; calibrator: unknown; evaluation: unknown; baselineUpProbability: number; trainThrough: string; trainingHash: string }, now = Date.now()) {
  const symbol = String(input.symbol ?? '').toUpperCase(), horizon = input.horizon;
  if (!symbolOK(symbol) || !(forecastModel.horizons as readonly string[]).includes(horizon)) invalid('symbol and horizon are invalid');
  if (!input.coefficients || !input.calibrator || !input.evaluation || !(input.baselineUpProbability > 0 && input.baselineUpProbability < 1) || !/^\d{4}-\d{2}-\d{2}$/.test(input.trainThrough) || !/^[a-f0-9]{64}$/.test(input.trainingHash)) invalid('candidate requires coefficients, calibration, evaluation, trainThrough and SHA-256 trainingHash');
  const support = (input.evaluation as any)?.support;
  if (!Number.isFinite(support?.train) || support.train < forecastModel.candidate.minimumTrainSessions || !Number.isFinite(support?.calibration) || support.calibration < forecastModel.candidate.minimumCalibrationSessions) invalid('candidate training and calibration support are below promotion minimums');
  const model = input.coefficients as any, calibration = input.calibrator as any;
  if (!Number.isFinite(model.intercept) || !model.weights || Object.values(model.weights).some(value => !Number.isFinite(value)) || !Number.isFinite(calibration.slope) || !Number.isFinite(calibration.intercept)) invalid('candidate coefficients and calibration must be finite');
  const priceOnly = (input as any).priceOnly;
  if (!priceOnly || !Number.isFinite(priceOnly.coefficients?.intercept) || !priceOnly.coefficients?.weights || Object.values(priceOnly.coefficients.weights).some(value => !Number.isFinite(value)) || !priceOnly.coefficients?.means || !priceOnly.coefficients?.scales || !Number.isFinite(priceOnly.calibrator?.slope) || !Number.isFinite(priceOnly.calibrator?.intercept)) invalid('candidate requires a finite price-only comparator');
  const coefficients = JSON.stringify({ coefficients: input.coefficients, calibrator: input.calibrator, priceOnly });
  const evaluationJSON = JSON.stringify({ ...(input.evaluation as any), baselineUpProbability: input.baselineUpProbability });
  const id = await sha256(`${forecastModel.candidate.version}|${symbol}|${horizon}|${input.trainThrough}|${input.trainingHash}|${coefficients}|${evaluationJSON}`);
  const createdAt = iso(now);
  await db.prepare(`INSERT INTO forecast_models (id,symbol,horizon,model_version,status,coefficients_json,evaluation_json,train_through,created_at)
    VALUES (?,?,?,'ridge-logit-shadow-v2','shadow',?,?,?,?) ON CONFLICT(id) DO NOTHING`).bind(id,symbol,horizon,coefficients,evaluationJSON,input.trainThrough,createdAt).run();
  return { id, symbol, horizon, status: 'shadow', model_version: 'ridge-logit-shadow-v2', training_hash: input.trainingHash, created_at: createdAt };
}

export async function evaluateForecastCandidate(db: DB, candidateId: string, now = Date.now()) {
  const candidate = await db.prepare("SELECT * FROM forecast_models WHERE id=? AND status IN ('shadow','promoted')").bind(candidateId).first<any>();
  if (!candidate) invalid('candidate not found');
  const { results } = await db.prepare(`SELECT p.probability_up,p.price_only_probability_up,p.outcome,f.session_date,f.price_only_direction
    FROM forecast_candidate_predictions p JOIN forecasts f ON f.id=p.forecast_id WHERE p.candidate_id=? AND p.outcome IS NOT NULL ORDER BY f.session_date`).bind(candidateId).all<any>();
  const scored = results.filter(row => row.outcome === 0 || row.outcome === 1);
  const baseProbability = Number(JSON.parse(candidate.evaluation_json)?.baselineUpProbability);
  const frozenBase = Number.isFinite(baseProbability) ? Math.max(0.01, Math.min(0.99, baseProbability)) : null;
  const baseRows = frozenBase === null ? [] : scored.map(row => ({ probability: frozenBase, outcome: row.outcome }));
  const modelRows = scored.map(row => ({ probability: row.probability_up, outcome: row.outcome }));
  const priceOnlyRows = scored.map(row => ({ probability: row.price_only_probability_up, outcome: row.outcome }));
  const sessions = new Set(scored.map(row => row.session_date)).size;
  const bins = calibrationBins(modelRows);
  const gate = promotionGate({ trainSessions: Number(JSON.parse(candidate.evaluation_json)?.support?.train ?? 0), calibrationSessions: Number(JSON.parse(candidate.evaluation_json)?.support?.calibration ?? 0),
    testSessions: sessions, candidateBrier: brierScore(modelRows), baselineBrier: brierScore(baseRows), priceOnlyBrier: brierScore(priceOnlyRows), bins });
  const degraded = scored.length >= forecastModel.candidate.promotionMinimumSessions && (!gate.beatsBaseline || !gate.calibrated);
  const status = gate.eligible ? 'promoted' : degraded ? 'rejected' : candidate.status;
  const evaluation = { ...JSON.parse(candidate.evaluation_json), forward: { predictions: scored.length, sessions, brier: brierScore(modelRows), baseline_brier: brierScore(baseRows), price_only_brier: brierScore(priceOnlyRows), bins }, gate };
  await db.prepare(`UPDATE forecast_models SET status=?,evaluation_json=?,promoted_at=CASE WHEN ?='promoted' THEN COALESCE(promoted_at,?) ELSE promoted_at END WHERE id=?`)
    .bind(status,JSON.stringify(evaluation),status,iso(now),candidateId).run();
  return { id: candidateId, status, evaluation };
}

const minimumJudgedSessions = 30;
const sampleStatus = (n: number) => n === 0 ? 'none' : n < minimumJudgedSessions ? 'too_few_to_judge' : 'judgeable';

function directionalScore(rows: any[]) {
  const decided = rows.filter(r => r.tilt === 'up' || r.tilt === 'down');
  const covered = decided.filter(r => r.direction !== 0);
  const sign = (s: string) => s === 'up' ? 1 : s === 'down' ? -1 : 0;
  const hit = (prediction: number, outcome: number) => prediction === outcome ? 1 : 0;
  const mean = (rs: any[], f: (r: any) => number) => rs.length ? rs.reduce((s, r) => s + f(r), 0) / rs.length : null;
  let priceN = 0, priceHits = 0, majorityN = 0, majorityHits = 0, yesterdayN = 0, yesterdayHits = 0;
  const ordered = [...rows].sort((a, b) => a.session_date.localeCompare(b.session_date));
  for (const row of covered) {
    const last = ordered.filter(p => p.horizon === row.horizon && p.session_date < row.session_date && p.direction !== 0).at(-1);
    if (last) { yesterdayN++; yesterdayHits += hit(last.direction, row.direction); }
    if (Number.isFinite(row.price_only_direction)) { priceN++; priceHits += hit(row.price_only_direction, row.direction); }
    const prior = ordered.filter(p => p.horizon === row.horizon && p.session_date < row.session_date && p.direction !== 0);
    if (prior.length >= 20) {
      const up = prior.filter(p => p.direction > 0).length / prior.length;
      majorityN++; majorityHits += hit(up >= 0.5 ? 1 : -1, row.direction);
    }
  }
  const bucket = (label: string, test: (score: number) => boolean) => {
    const group = covered.filter(r => Number.isFinite(r.score) && test(r.score));
    return { label, scored: group.length, hit_rate: group.length ? group.filter(r => sign(r.tilt) === r.direction).length / group.length : null, sample: sampleStatus(group.length) };
  };
  const neutral = rows.filter(r => r.tilt === 'neutral').length;
  return { count: rows.length, scored: covered.length, sample: sampleStatus(covered.length), minimum_sessions: minimumJudgedSessions,
    abstained: neutral, abstain_rate: rows.length ? neutral / rows.length : null,
    always_up_baseline_hit_rate: covered.length ? covered.filter(r => r.direction > 0).length / covered.length : null,
    yesterday_baseline_hit_rate: yesterdayN ? yesterdayHits / yesterdayN : null,
    confidence_buckets: [bucket('strong (≥65 or ≤35)', x => x >= 65 || x <= 35), bucket('moderate (55–65 or 35–45)', x => (x >= 55 && x < 65) || (x > 35 && x <= 45))],
    hit_rate: covered.length ? covered.filter(r => sign(r.tilt) === r.direction).length / covered.length : null,
    mean_return_pct: mean(rows, r => r.return_pct), tilt_return_pct: mean(decided, r => sign(r.tilt) * r.return_pct),
    base_rate_up: rows.length ? rows.filter(r => r.direction > 0).length / rows.length : null,
    majority_baseline_hit_rate: majorityN ? majorityHits / majorityN : null,
    price_only_baseline_hit_rate: priceN ? priceHits / priceN : null, price_only_baseline: 'frozen sign of market-only pulse points at capture',
    majority_baseline: 'prior-session majority direction; at least 20 earlier outcomes; evaluated only on the same covered outcomes' };
}

function compactForecast(row: any, evidence: { evidence: any[]; contradictions: any[] } = { evidence: [], contradictions: [] }) {
  const hasOutcome = row.return_pct !== null && row.return_pct !== undefined && Number.isFinite(Number(row.return_pct));
  return { id: row.id, symbol: row.symbol, session_date: row.session_date, horizon: row.horizon, forecast_at: row.forecast_at,
    target_start_at: row.target_start_at, target_end_at: row.target_end_at, model_version: row.model_version, input_version: row.input_version,
    score: row.score, tilt: row.tilt, probability_up: null, headline: row.headline ?? null, summary: row.summary ?? null,
    outcome: hasOutcome ? { baseline_price: row.baseline_price, baseline_at: row.baseline_at, endpoint_price: row.endpoint_price,
      endpoint_at: row.endpoint_at, return_pct: row.return_pct, direction: row.direction, source: row.outcome_source, source_retrieved_at: row.source_retrieved_at } : null,
    evidence: evidence.evidence, contradictions: evidence.contradictions, created_at: row.created_at };
}

function snapshotDrivers(snapshot: any, tilt: string) {
  const evidence: any[] = [], contradictions: any[] = [];
  const expected = tilt === 'up' ? 1 : tilt === 'down' ? -1 : 0;
  const add = (item: any, direction: number) => {
    const dto = { title: item.title, source: item.source, url: item.url, received_at: item.received_at, at: item.at ?? item.published_at, reason: item.reason ?? item.channel ?? item.detail };
    if (!dto.title) return;
    if (expected && direction && Math.sign(direction) !== expected) contradictions.push(dto);
    else evidence.push(dto);
  };
  for (const channel of snapshot?.pulse?.components?.news?.channels ?? []) for (const item of channel.top ?? []) add({ ...item, reason: item.reason ?? channel.channel }, item.direction ?? item.weight);
  for (const driver of snapshot?.pulse?.drivers ?? []) if (driver.kind === 'news') add(driver, driver.direction ?? (driver.effect === 'lower' ? -1 : driver.effect === 'higher' ? 1 : 0));
  // Earlier frozen snapshots used factor-linked rule evidence.
  for (const factor of snapshot?.pulse?.factors ?? []) for (const item of factor.evidence ?? []) add({ ...item, reason: item.reason ?? factor.factor }, item.direction);
  const unique = (items: any[]) => {
    const byStory = new Map<string, any>();
    for (const item of items) {
      const key = `${item.url}|${item.title}`, previous = byStory.get(key);
      byStory.set(key, previous ? { ...item, ...previous, received_at: previous.received_at ?? item.received_at, at: previous.at ?? item.at } : item);
    }
    return [...byStory.values()].slice(0, 6);
  };
  return { evidence: unique(evidence), contradictions: unique(contradictions) };
}

export async function getResearch(db: DB, symbol: string) {
  symbol = String(symbol ?? '').toUpperCase();
  if (!symbolOK(symbol)) invalid('symbol must be SPY or QQQ');
  const [forecasts, questions, activeModel] = await Promise.all([
    db.prepare(`SELECT f.id,f.symbol,f.session_date,f.horizon,f.forecast_at,f.target_start_at,f.target_end_at,f.model_version,f.input_version,f.score,f.tilt,f.created_at,
      CASE WHEN json_valid(f.snapshot_json) THEN json_extract(f.snapshot_json,'$.pulse.call.headline') END AS headline,
      CASE WHEN json_valid(f.snapshot_json) THEN json_extract(f.snapshot_json,'$.pulse.summary') END AS summary,
      f.price_only_direction,o.baseline_price,o.baseline_at,o.endpoint_price,o.endpoint_at,o.return_pct,o.direction,o.source AS outcome_source,o.source_retrieved_at
      FROM forecasts f LEFT JOIN forecast_outcomes o ON o.forecast_id=f.id WHERE f.symbol=? ORDER BY f.forecast_at DESC,f.session_date DESC LIMIT 300`).bind(symbol).all<any>(),
    db.prepare("SELECT id,query,reason,status,created_at,event_id FROM research_questions WHERE status IN ('open','queued') ORDER BY created_at DESC LIMIT 30").all<any>(),
    db.prepare("SELECT * FROM forecast_models WHERE symbol=? AND model_version='ridge-logit-shadow-v2' AND status='promoted' ORDER BY created_at DESC LIMIT 1").bind(symbol).first<any>(),
  ]);
  const rows = forecasts.results, settled = rows.filter(r => r.model_version === adaptiveVersion && r.return_pct !== null && r.return_pct !== undefined);
  const byHorizon = Object.fromEntries(forecastModel.horizons.map(h => [h, directionalScore(settled.filter(r => r.horizon === h))]));
  const latest = rows[0] ?? null;
  let latestDrivers: { evidence: any[]; contradictions: any[] } = { evidence: [], contradictions: [] };
  if (latest) {
    const snapshot = await db.prepare('SELECT snapshot_json FROM forecasts WHERE id=?').bind(latest.id).first<{ snapshot_json: string }>();
    try { latestDrivers = snapshotDrivers(JSON.parse(snapshot?.snapshot_json ?? '{}'), latest.tilt); } catch { /* corrupt legacy snapshot has no display evidence */ }
  }
  const probabilityRows = activeModel ? await db.prepare('SELECT forecast_id,probability_up FROM forecast_candidate_predictions WHERE candidate_id=?').bind(activeModel.id).all<any>() : { results: [] };
  const probabilityById = new Map(probabilityRows.results.map(row => [row.forecast_id, row.probability_up]));
  const recent = rows.slice(0, 90).map(row => ({ ...compactForecast(row), probability_up: probabilityById.get(row.id) ?? null }));
  const latestDTO = latest ? { ...compactForecast(latest, latestDrivers), probability_up: probabilityById.get(latest.id) ?? null } : null;
  return { symbol, status: latest ? (latest.tilt === 'unavailable' ? 'limited' : 'available') : 'collecting',
    summary: latest ? `${latest.tilt} research tilt; experimental and uncalibrated` : 'Collecting frozen forecasts; no probability estimate is validated.',
    latest: latestDTO, performance: { model_version: adaptiveVersion, excluded_legacy: rows.filter(r => r.model_version !== adaptiveVersion && r.return_pct !== null && r.return_pct !== undefined).length, settled: settled.length, horizons: byHorizon, probability_metrics: null,
      candidate_status: 'adaptive learning', candidate: activeModel ? JSON.parse(activeModel.evaluation_json) : null },
    recent, questions: questions.results.map(({ event_id, ...q }) => ({ ...q, ...(event_id ? { event_id } : {}) })),
    model: { ...forecastModel, active_candidate: activeModel ? { version: activeModel.model_version, promoted_at: activeModel.promoted_at } : null } };
}
