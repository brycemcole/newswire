import { forecastTilt, makeFeatures, type Features, type Horizon } from './forecast-model';

export const adaptiveVersion = 'forecast-adaptive-v1';
const coefficients: Record<string, number> = { score_delta: 16, news_points: 7, market_points: 7, calendar_points: 3 };
export type LearningOutcome = { id: string; session_date: string; horizon: Horizon; available_at: string; direction: number; features: Features };
const round = (value: number) => Math.round(value * 100) / 100;
const bounded = (value: number, limit: number) => Math.max(-limit, Math.min(limit, value));

export async function learningOutcomes(db: D1Database, symbol: string, asOf: string): Promise<LearningOutcome[]> {
  if (!['SPY', 'QQQ'].includes(symbol)) return [];
  const { results } = await db.prepare(`SELECT f.id,f.session_date,f.horizon,f.features_json,o.direction,o.ingested_at AS available_at
    FROM forecasts f JOIN forecast_outcomes o ON o.forecast_id=f.id
    WHERE f.symbol=? AND o.ingested_at<=? AND f.target_end_at<=? AND f.tilt!='unavailable'
    ORDER BY f.session_date DESC,f.id LIMIT 180`).bind(symbol, asOf, asOf).all<any>();
  return results.flatMap(row => {
    try {
      const features = JSON.parse(row.features_json);
      return features && Object.values(features).every(value => typeof value === 'number' && Number.isFinite(value)) ? [{ ...row, features }] : [];
    } catch { return []; }
  });
}

export function adaptiveForecast(features: Features, rows: LearningOutcome[], horizon: Horizon, asOf: string) {
  const base = forecastTilt(features);
  const unique = new Map(rows.filter(row => row.available_at <= asOf && [-1, 0, 1].includes(row.direction)
    && Object.values(row.features).every(Number.isFinite) && forecastTilt(row.features).score !== null).map(row => [row.id, row]));
  const usable = [...unique.values()].sort((a, b) => a.session_date.localeCompare(b.session_date) || a.id.localeCompare(b.id)).slice(-180);
  const sessions = [...new Set(usable.map(row => row.session_date))];
  const corrections = Object.fromEntries(Object.keys(coefficients).map(key => [key, 0]));
  const support = { ...corrections };
  for (const row of usable) {
    const age = sessions.length - 1 - sessions.indexOf(row.session_date);
    const dayCount = usable.filter(item => item.session_date === row.session_date).length;
    const weight = 2 ** (-age / 10) * (row.horizon === horizon ? 1 : 0.25) / dayCount;
    const error = 50 + 15 * row.direction - forecastTilt(row.features).score!;
    for (const key of Object.keys(coefficients)) {
      const x = bounded(row.features[key] ?? 0, 1);
      corrections[key] += weight * x * error;
      support[key] += weight * x * x;
    }
  }
  let adjustment = 0;
  const weights: Record<string, number> = {};
  for (const [key, prior] of Object.entries(coefficients)) {
    const correction = bounded(corrections[key] / (8 + support[key]), prior);
    weights[key] = round(prior + correction);
    adjustment += correction * bounded(features[key] ?? 0, 1);
  }
  adjustment = base.score === null ? 0 : round(bounded(adjustment, 12));
  const score = base.score === null ? null : round(Math.max(0, Math.min(100, base.score + adjustment)));
  return { model: adaptiveVersion, score, tilt: score === null ? 'unavailable' : score >= 55 ? 'up' : score <= 45 ? 'down' : 'neutral',
    probability_up: null, base_score: base.score, adjustment, horizon, settled: usable.length,
    same_horizon: usable.filter(row => row.horizon === horizon).length, sessions: sessions.length,
    updated_through: usable.map(row => row.available_at).sort().at(-1) ?? null, weights,
    status: usable.length ? 'learning' : 'starting',
    note: usable.length ? `Learning from ${usable.length} completed forecast${usable.length === 1 ? '' : 's'} across ${sessions.length} trading session${sessions.length === 1 ? '' : 's'}. Recent results count more; other forecast periods count less. Experimental index, not a probability.`
      : 'Using current market evidence now. Adjustments begin with the first completed forecast. Experimental index, not a probability.' };
}

export function adaptPulse<T extends { symbol: string; as_of: string; horizon?: string; score: number | null; research_score: number | null; outlook: string }>(pulse: T, rows: LearningOutcome[]) {
  if (!['SPY', 'QQQ'].includes(pulse.symbol)) return { ...pulse, learning: null };
  const horizon = pulse.horizon === 'next open' ? 'opening_gap' : 'open_to_close';
  const learning = adaptiveForecast(makeFeatures({ pulse }), rows, horizon, pulse.as_of);
  return { ...pulse, score: learning.score, research_score: learning.score,
    outlook: learning.score === null ? 'unavailable' : learning.score < 40 ? 'headwinds' : learning.score > 60 ? 'tailwinds' : 'balanced', learning };
}
