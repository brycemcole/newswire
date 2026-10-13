import { forecastTilt, makeFeatures, type Features, type Horizon } from './forecast-model';

export const adaptiveVersion = 'forecast-adaptive-v2';
const coefficients: Record<string, number> = { news_points: 25, market_points: 35, calendar_points: 10, earnings_points: 10 };
export type LearningOutcome = { id: string; session_date: string; horizon: Horizon; available_at: string; direction: number; return_pct: number; forecast_at: string; features: Features };
const round = (value: number) => Math.round(value * 100) / 100;
const bounded = (value: number, limit: number) => Math.max(-limit, Math.min(limit, value));

export async function learningOutcomes(db: D1Database, symbol: string, asOf: string, horizon?: Horizon): Promise<LearningOutcome[]> {
  if (!['SPY', 'QQQ'].includes(symbol)) return [];
  const { results } = await db.prepare(`SELECT f.id,f.session_date,f.horizon,f.features_json,f.forecast_at,o.direction,o.return_pct,o.ingested_at AS available_at
    FROM forecasts f JOIN forecast_outcomes o ON o.forecast_id=f.id
    WHERE f.symbol=? AND o.ingested_at<=? AND f.target_end_at<=? AND f.tilt!='unavailable' AND f.model_version=? AND (? IS NULL OR f.horizon=?)
    ORDER BY f.session_date DESC,f.id LIMIT 540`).bind(symbol, asOf, asOf, adaptiveVersion, horizon ?? null, horizon ?? null).all<any>();
  return results.flatMap(row => {
    try {
      const features = JSON.parse(row.features_json);
      return features && Object.values(features).every(value => typeof value === 'number' && Number.isFinite(value)) ? [{ ...row, features }] : [];
    } catch { return []; }
  });
}

export function adaptiveForecast(features: Features, rows: LearningOutcome[], horizon: Horizon, asOf: string) {
  const base = forecastTilt(features);
  const unique = new Map(rows.filter(row => row.horizon === horizon && row.available_at <= asOf
    && Number.isFinite(row.return_pct) && Object.values(row.features).every(Number.isFinite)
    && forecastTilt(row.features).score !== null).map(row => [row.session_date, row]));
  const usable = [...unique.values()].sort((a, b) => a.session_date.localeCompare(b.session_date)).slice(-180);
  const normalized = usable.flatMap(row => {
    const prior = usable.filter(old => old.session_date < row.session_date && old.available_at <= row.forecast_at).slice(-20);
    if (prior.length < 20) return [];
    const mean = prior.reduce((sum, old) => sum + old.return_pct, 0) / 20;
    const sigma = Math.sqrt(prior.reduce((sum, old) => sum + (old.return_pct - mean) ** 2, 0) / 19);
    if (!(sigma > 1e-6)) return [];
    return [{ row, target: 50 + 15 * bounded(row.return_pct / sigma, 3) }];
  });
  const ready = normalized.length >= 60;
  const keys = Object.keys(coefficients);
  const matrix = keys.map((_, i) => keys.map((_, j) => i === j ? 8 : 0));
  const rhs = keys.map(() => 0);
  if (ready) for (const [index, { row, target }] of normalized.entries()) {
    const weight = 2 ** (-(normalized.length - 1 - index) / 60);
    const x = keys.map(key => bounded(row.features[key] ?? 0, 1));
    const error = target - forecastTilt(row.features).score!;
    for (let i = 0; i < keys.length; i++) {
      rhs[i] += weight * x[i] * error;
      for (let j = 0; j < keys.length; j++) matrix[i][j] += weight * x[i] * x[j];
    }
  }
  // Ridge makes the system positive definite even when evidence channels coincide.
  for (let i = 0; i < keys.length; i++) {
    const pivot = matrix[i][i];
    for (let j = i; j < keys.length; j++) matrix[i][j] /= pivot;
    rhs[i] /= pivot;
    for (let k = 0; k < keys.length; k++) if (k !== i) {
      const factor = matrix[k][i];
      for (let j = i; j < keys.length; j++) matrix[k][j] -= factor * matrix[i][j];
      rhs[k] -= factor * rhs[i];
    }
  }
  const weights = Object.fromEntries(keys.map((key, i) => [key, round(coefficients[key] + rhs[i])]));
  const adjustment = base.score === null ? 0 : round(bounded(keys.reduce((sum, key, i) => sum + rhs[i] * bounded(features[key] ?? 0, 1), 0), 12));
  const score = base.score === null ? null : round(Math.max(0, Math.min(100, base.score + adjustment)));
  return { model: adaptiveVersion, score, tilt: score === null ? 'unavailable' : score >= 55 ? 'up' : score <= 45 ? 'down' : 'neutral',
    probability_up: null, base_score: base.score, adjustment, horizon, settled: usable.length,
    same_horizon: usable.length, sessions: usable.length, training_sessions: normalized.length, minimum_sessions: 60,
    updated_through: usable.map(row => row.available_at).sort().at(-1) ?? null, weights,
    status: ready ? 'learning' : 'collecting',
    note: ready ? `Learning from ${normalized.length} sessions in this forecast period using joint ridge regression and volatility-scaled returns. Experimental index, not a probability.`
      : `Collecting: ${normalized.length}/60 eligible sessions in this forecast period, after 20 prior returns for volatility. Live scores are unchanged by learning. Experimental index, not a probability.` };
}

export function adaptPulse<T extends { symbol: string; as_of: string; horizon?: string; score: number | null; research_score: number | null; outlook: string }>(pulse: T, rows: LearningOutcome[]) {
  if (!['SPY', 'QQQ'].includes(pulse.symbol)) return { ...pulse, learning: null };
  const horizon = pulse.horizon === 'next open' ? 'opening_gap' : 'open_to_close';
  const learning = adaptiveForecast(makeFeatures({ pulse }), rows, horizon, pulse.as_of);
  if (learning.status !== 'learning') return { ...pulse, learning };
  return { ...pulse, score: learning.score, research_score: learning.score,
    outlook: learning.score === null ? 'unavailable' : learning.score < 40 ? 'headwinds' : learning.score > 60 ? 'tailwinds' : 'balanced', learning };
}
