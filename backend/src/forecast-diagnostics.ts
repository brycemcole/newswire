import { defaultTilt, forecastTilt, marketGroupKeys, tiltBounds, type Features, type Horizon, type TiltParams } from './forecast-model';

export type SettledForecast = { id?: string; session_date: string; horizon: Horizon; forecast_at: string; score: number | null; tilt: string;
  price_only_direction: number | null; return_pct: number; direction: number; features: Features };
export type ImpactRecord = { received_at: string; published_at?: string; direction: number; channel: string; size: 'major' | 'moderate' | 'minor'; confidence: number };

const round = (value: number, places = 4) => Math.round(value * 10 ** places) / 10 ** places;
const sum = (values: number[]) => values.reduce((total, value) => total + value, 0);
const mean = (values: number[]) => values.length ? sum(values) / values.length : null;
const sd = (values: number[]) => {
  if (values.length < 2) return null;
  const m = sum(values) / values.length;
  return Math.sqrt(sum(values.map(value => (value - m) ** 2)) / (values.length - 1));
};
const tStat = (values: number[]) => {
  const s = sd(values);
  return s && s > 1e-12 ? (sum(values) / values.length) / (s / Math.sqrt(values.length)) : null;
};
export function correlation(xs: number[], ys: number[]): number | null {
  if (xs.length < 3 || xs.length !== ys.length) return null;
  const mx = sum(xs) / xs.length, my = sum(ys) / ys.length;
  let sxy = 0, sxx = 0, syy = 0;
  for (let i = 0; i < xs.length; i++) { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) ** 2; syy += (ys[i] - my) ** 2; }
  return sxx > 1e-12 && syy > 1e-12 ? sxy / Math.sqrt(sxx * syy) : null;
}
const sign = (value: number) => value > 0 ? 1 : value < 0 ? -1 : 0;
const tiltSign = (tilt: string) => tilt === 'up' ? 1 : tilt === 'down' ? -1 : 0;

export const minimumJudged = 30;
const termCoefficients: Record<string, number> = { news_points: 25, ...Object.fromEntries(marketGroupKeys.map(key => [key, 40])), calendar_points: 10, earnings_points: 10 };

// Points each term contributed to the score, mirroring forecastTilt, so a miss can be traced to the terms that pointed the wrong way.
export function termContributions(features: Features, params: TiltParams = defaultTilt): Record<string, number> {
  const hasGroups = marketGroupKeys.some(key => key in features);
  const scale = params.gain * (1 - params.eventShrink * Math.max(0, Math.min(1, features.event_risk ?? 0)));
  const out: Record<string, number> = {};
  for (const key of Object.keys(termCoefficients)) {
    if (!hasGroups && marketGroupKeys.includes(key)) continue;
    out[key] = termCoefficients[key] * (features[key] ?? 0) * scale;
  }
  if (!hasGroups) out.market_points = 40 * (features.market_points ?? 0) * scale;
  return out;
}

export type TermVerdict = 'helps' | 'hurts' | 'noise' | 'insufficient';
export function missReport(rows: SettledForecast[], params: TiltParams = defaultTilt, worstCount = 10) {
  const usable = rows.filter(row => Number.isFinite(row.return_pct) && row.score !== null && row.tilt !== 'unavailable')
    .sort((a, b) => a.session_date.localeCompare(b.session_date) || a.forecast_at.localeCompare(b.forecast_at));
  const called = usable.filter(row => tiltSign(row.tilt) !== 0 && row.direction !== 0);
  const signed = called.map(row => tiltSign(row.tilt) * row.return_pct);
  const hits = called.filter(row => tiltSign(row.tilt) === row.direction).length;
  const priced = called.filter(row => row.price_only_direction !== null && row.price_only_direction !== 0);
  const moved = usable.filter(row => row.direction !== 0);
  const upRate = moved.length ? moved.filter(row => row.direction > 0).length / moved.length : null;
  const overall = { sessions: usable.length, called: called.length, abstained: usable.length - called.length,
    hit_rate: called.length ? round(hits / called.length) : null, mean_signed_return_pct: mean(signed) === null ? null : round(mean(signed)!),
    signed_return_t: tStat(signed) === null ? null : round(tStat(signed)!, 2),
    score_return_correlation: (() => { const c = correlation(usable.map(row => row.score! - 50), usable.map(row => row.return_pct)); return c === null ? null : round(c); })(),
    always_up_hit_rate: called.length && upRate !== null ? round(called.filter(row => row.direction > 0).length / called.length) : null,
    price_only_hit_rate: priced.length ? round(priced.filter(row => row.price_only_direction === row.direction).length / priced.length) : null,
    neutral_signed_return_pct: 0, up_rate: upRate === null ? null : round(upRate) };

  const terms = Object.keys(termCoefficients).map(key => {
    const points = usable.map(row => ({ row, points: termContributions(row.features, params)[key] ?? 0 }));
    const active = points.filter(item => Math.abs(item.points) >= 0.5 && item.row.direction !== 0);
    const edge = active.map(item => sign(item.points) * item.row.return_pct);
    const t = tStat(edge);
    const c = correlation(points.map(item => item.points), points.map(item => item.row.return_pct));
    const verdict: TermVerdict = active.length < minimumJudged || t === null ? 'insufficient' : t >= 1.65 ? 'helps' : t <= -1.65 ? 'hurts' : 'noise';
    return { term: key, active: active.length, agree_rate: active.length ? round(active.filter(item => sign(item.points) === item.row.direction).length / active.length) : null,
      mean_signed_return_pct: mean(edge) === null ? null : round(mean(edge)!), t: t === null ? null : round(t, 2), correlation: c === null ? null : round(c),
      bias_points: round(mean(points.map(item => item.points)) ?? 0, 2), verdict };
  });

  const worst = called.map(row => ({ row, loss: -tiltSign(row.tilt) * row.return_pct })).filter(item => item.loss > 0)
    .sort((a, b) => b.loss - a.loss).slice(0, worstCount).map(({ row, loss }) => {
      const contributions = Object.entries(termContributions(row.features, params)).filter(([, points]) => sign(points) === tiltSign(row.tilt))
        .sort((a, b) => Math.abs(b[1]) - Math.abs(a[1])).slice(0, 3).map(([term, points]) => ({ term, points: round(points, 2) }));
      return { session_date: row.session_date, horizon: row.horizon, score: row.score, tilt: row.tilt, return_pct: round(row.return_pct), loss_pct: round(loss), misled_by: contributions };
    });

  const recent = called.slice(-30);
  const rolling = recent.length >= minimumJudged ? { sessions: recent.length, hit_rate: round(recent.filter(row => tiltSign(row.tilt) === row.direction).length / recent.length),
    mean_signed_return_pct: round(mean(recent.map(row => tiltSign(row.tilt) * row.return_pct))!) } : null;
  return { overall, rolling, terms, worst };
}

// Monotone (pool-adjacent-violators) map from score to the observed frequency of an up move, so a score can be read as a probability once enough sessions exist.
export function calibrationMap(rows: SettledForecast[], minimumRows = 60) {
  const points = rows.filter(row => row.score !== null && row.direction !== 0).map(row => ({ score: row.score!, up: row.direction > 0 ? 1 : 0 })).sort((a, b) => a.score - b.score);
  if (points.length < minimumRows) return { status: 'insufficient' as const, sessions: points.length, minimum: minimumRows, steps: [] as Array<{ score_max: number; p_up: number; n: number }> };
  const blocks = points.map(point => ({ sum: point.up, n: 1, max: point.score }));
  const merged: typeof blocks = [];
  for (const block of blocks) {
    merged.push({ ...block });
    while (merged.length > 1 && merged.at(-2)!.sum / merged.at(-2)!.n > merged.at(-1)!.sum / merged.at(-1)!.n) {
      const last = merged.pop()!, previous = merged.pop()!;
      merged.push({ sum: previous.sum + last.sum, n: previous.n + last.n, max: last.max });
    }
  }
  // Smoothing small blocks toward one half can break the order, so pool again on the smoothed values.
  const smoothed: Array<{ mass: number; n: number; max: number }> = [];
  for (const block of merged) {
    smoothed.push({ mass: (block.sum + 1) / (block.n + 2) * block.n, n: block.n, max: block.max });
    while (smoothed.length > 1 && smoothed.at(-2)!.mass / smoothed.at(-2)!.n > smoothed.at(-1)!.mass / smoothed.at(-1)!.n) {
      const last = smoothed.pop()!, previous = smoothed.pop()!;
      smoothed.push({ mass: previous.mass + last.mass, n: previous.n + last.n, max: last.max });
    }
  }
  const steps = smoothed.map(block => ({ score_max: block.max, p_up: round(Math.max(0.02, Math.min(0.98, block.mass / block.n))), n: block.n }));
  return { status: 'ready' as const, sessions: points.length, minimum: minimumRows, steps };
}
export function applyCalibration(map: ReturnType<typeof calibrationMap>, score: number): number | null {
  if (map.status !== 'ready') return null;
  return (map.steps.find(step => score <= step.score_max) ?? map.steps.at(-1)!).p_up;
}

const halfLives = [3, 6, 12, 24, 48];
const sizeWeight = { major: 1, moderate: 0.5, minor: 0.2 } as const;
const windowMs = 96 * 3600000;
export const channelNames = ['energy', 'rates', 'trade', 'growth', 'credit', 'geopolitics', 'earnings'] as const;

// Re-derive each channel's signal from the stored impacts under several half-lives and compare it with the realized move.
export function channelDiagnostics(rows: SettledForecast[], impacts: ImpactRecord[]) {
  const usable = rows.filter(row => Number.isFinite(row.return_pct) && row.direction !== 0).sort((a, b) => a.forecast_at.localeCompare(b.forecast_at));
  const sorted = impacts.filter(item => item.confidence >= 0.5 && item.direction !== 0 && item.size in sizeWeight).map(item => ({ ...item, at: Date.parse(item.received_at) }))
    .filter(item => Number.isFinite(item.at)).sort((a, b) => a.at - b.at);
  return channelNames.map(channel => {
    const own = sorted.filter(item => item.channel === channel);
    const byHalfLife = halfLives.map(halfLife => {
      const signals: number[] = [], returns: number[] = [];
      for (const row of usable) {
        const at = Date.parse(row.forecast_at);
        let total = 0, count = 0;
        for (const item of own) {
          if (item.at > at) break;
          const age = at - item.at;
          if (age > windowMs) continue;
          total += item.direction * sizeWeight[item.size] * item.confidence * 2 ** (-age / 3600000 / halfLife);
          count++;
        }
        if (count) { signals.push(Math.tanh(total / 1.5)); returns.push(row.return_pct); }
      }
      const edge = signals.map((signal, i) => sign(signal) * returns[i]);
      const c = correlation(signals, returns), t = tStat(edge);
      return { half_life_hours: halfLife, active: signals.length, correlation: c === null ? null : round(c), mean_signed_return_pct: mean(edge) === null ? null : round(mean(edge)!), t: t === null ? null : round(t, 2) };
    });
    const current = byHalfLife.find(item => item.half_life_hours === 12)!;
    const scored = byHalfLife.filter(item => item.t !== null && item.active >= minimumJudged);
    const best = scored.sort((a, b) => b.t! - a.t!)[0] ?? null;
    const recommendation = !best ? 'insufficient' : (current.t ?? 0) <= -1.65 ? 'invert_or_drop' : (current.t ?? 0) < 0.5 && best.t! < 1 ? 'shrink' : best.half_life_hours !== 12 && best.t! - (current.t ?? 0) >= 1 ? `half_life_${best.half_life_hours}h` : 'keep';
    return { channel, impacts: own.length, current, best, by_half_life: byHalfLife, recommendation };
  });
}

type TuneRow = { row: SettledForecast; return_pct: number };
const utility = (rows: TuneRow[], params: TiltParams) => {
  let total = 0;
  for (const { row, return_pct } of rows) total += tiltSign(forecastTilt(row.features, params).tilt) * return_pct;
  return rows.length ? total / rows.length : 0;
};
export function tiltGrid(): TiltParams[] {
  const grid: TiltParams[] = [];
  for (const eventShrink of [0, 0.2, 0.4, 0.6, 0.8]) for (const gain of [0.6, 0.8, 1, 1.25, 1.5]) for (const band of [2, 3.5, 5, 7, 10]) grid.push({ eventShrink, gain, band });
  return grid.filter(p => p.eventShrink >= tiltBounds.eventShrink[0] && p.gain >= tiltBounds.gain[0] && p.band >= tiltBounds.band[0]);
}

const rowStats = (rows: SettledForecast[], params: TiltParams) => {
  const moved = rows.filter(row => row.direction !== 0 && Number.isFinite(row.return_pct));
  const calls = moved.map(row => ({ call: tiltSign(forecastTilt(row.features, params).tilt), row })).filter(item => item.call !== 0);
  const signed = calls.map(item => item.call * item.row.return_pct);
  return { sessions: moved.length, called: calls.length, hit_rate: calls.length ? calls.filter(item => item.call === item.row.direction).length / calls.length : null,
    mean_signed_return_pct: moved.length ? sum(signed) / moved.length : 0 };
};
export const backtestRules = { conclusiveSessions: 60 };
// Replays every settled session under both parameter sets. A change is "not worse" only if it matches or beats the baseline on return and hit rate over all history.
export function backtestComparison(rows: SettledForecast[], candidate: TiltParams, baseline: TiltParams = defaultTilt) {
  const a = rowStats(rows, baseline), b = rowStats(rows, candidate);
  const gain = b.mean_signed_return_pct - a.mean_signed_return_pct;
  const hitGain = (b.hit_rate ?? 0) - (a.hit_rate ?? 0);
  const notWorse = gain >= -1e-12 && hitGain >= -1e-12;
  return { sessions: a.sessions, conclusive: a.sessions >= backtestRules.conclusiveSessions,
    baseline: { called: a.called, hit_rate: a.hit_rate === null ? null : round(a.hit_rate), mean_signed_return_pct: round(a.mean_signed_return_pct) },
    candidate: { called: b.called, hit_rate: b.hit_rate === null ? null : round(b.hit_rate), mean_signed_return_pct: round(b.mean_signed_return_pct) },
    gain_pct: round(gain), hit_rate_gain: round(hitGain), not_worse: notWorse, better: notWorse && (gain > 1e-12 || hitGain > 1e-12) };
}

export const tuneRules = { minimumTrainSessions: 60, minimumOutOfSample: 60, refitEvery: 5, minimumMeanGain: 0.01, minimumT: 1.28 };

// Expanding-window walk-forward: every parameter choice is made only from sessions before the one it is scored on.
export function tuneTilt(rows: SettledForecast[], current: TiltParams = defaultTilt) {
  const ordered = rows.filter(row => Number.isFinite(row.return_pct) && row.direction !== 0 && row.score !== null)
    .sort((a, b) => a.session_date.localeCompare(b.session_date) || a.forecast_at.localeCompare(b.forecast_at));
  const spread = sd(ordered.map(row => row.return_pct));
  if (ordered.length < tuneRules.minimumTrainSessions + tuneRules.minimumOutOfSample || !spread) return { status: 'insufficient' as const, sessions: ordered.length,
    needed: tuneRules.minimumTrainSessions + tuneRules.minimumOutOfSample, proposal: null, out_of_sample: null };
  const clip = 3 * spread;
  const clipped: TuneRow[] = ordered.map(row => ({ row, return_pct: Math.max(-clip, Math.min(clip, row.return_pct)) }));
  const grid = tiltGrid();
  const best = (past: TuneRow[]) => grid.map(params => ({ params, value: utility(past, params) }))
    .sort((a, b) => b.value - a.value || Math.abs(a.params.gain - 1) - Math.abs(b.params.gain - 1))[0].params;
  const proposed: number[] = [], kept: number[] = [];
  let chosen = current;
  for (let i = tuneRules.minimumTrainSessions; i < clipped.length; i++) {
    if ((i - tuneRules.minimumTrainSessions) % tuneRules.refitEvery === 0) chosen = best(clipped.slice(0, i));
    proposed.push(tiltSign(forecastTilt(clipped[i].row.features, chosen).tilt) * clipped[i].return_pct);
    kept.push(tiltSign(forecastTilt(clipped[i].row.features, current).tilt) * clipped[i].return_pct);
  }
  const diff = proposed.map((value, i) => value - kept[i]);
  const t = tStat(diff);
  const final = best(clipped);
  const meanGain = mean(diff) ?? 0;
  const backtest = backtestComparison(ordered, final, current);
  const eligible = backtest.not_worse && diff.length >= tuneRules.minimumOutOfSample && meanGain >= tuneRules.minimumMeanGain && t !== null && t >= tuneRules.minimumT && (mean(proposed) ?? 0) > 0;
  return { status: eligible ? 'proposal' as const : 'no_improvement' as const, sessions: ordered.length,
    proposal: eligible ? final : null, fitted: final, backtest,
    out_of_sample: { sessions: diff.length, proposed_mean_return_pct: round(mean(proposed)!), current_mean_return_pct: round(mean(kept)!), mean_gain_pct: round(meanGain), paired_t: t === null ? null : round(t, 2) },
    train_through: ordered.at(-1)!.session_date };
}

export type DriftAlert = { kind: 'term_turned_harmful' | 'hit_rate_below_baseline' | 'channel_inverted' | 'skill_lost'; detail: string };
export function driftAlerts(report: ReturnType<typeof missReport>, channels: ReturnType<typeof channelDiagnostics>, previous?: { terms?: Array<{ term: string; verdict: string }>; channels?: Array<{ channel: string; recommendation: string }> } | null): DriftAlert[] {
  const alerts: DriftAlert[] = [];
  for (const term of report.terms) {
    const before = previous?.terms?.find(item => item.term === term.term)?.verdict;
    if (term.verdict === 'hurts' && before !== 'hurts') alerts.push({ kind: 'term_turned_harmful', detail: `${term.term} now loses ${term.mean_signed_return_pct}% per active session (t=${term.t}).` });
  }
  for (const item of channels) {
    const before = previous?.channels?.find(entry => entry.channel === item.channel)?.recommendation;
    if (item.recommendation === 'invert_or_drop' && before !== 'invert_or_drop') alerts.push({ kind: 'channel_inverted', detail: `${item.channel} headlines move the market against their stated direction (t=${item.current.t}).` });
  }
  const { rolling, overall } = report;
  if (rolling && overall.always_up_hit_rate !== null && rolling.hit_rate < overall.always_up_hit_rate - 0.1)
    alerts.push({ kind: 'hit_rate_below_baseline', detail: `Last ${rolling.sessions} calls hit ${(rolling.hit_rate * 100).toFixed(0)}%, ${((overall.always_up_hit_rate - rolling.hit_rate) * 100).toFixed(0)} points under always-up.` });
  if (rolling && rolling.mean_signed_return_pct < 0 && overall.mean_signed_return_pct !== null && overall.mean_signed_return_pct > 0)
    alerts.push({ kind: 'skill_lost', detail: `Last ${rolling.sessions} calls lost ${Math.abs(rolling.mean_signed_return_pct)}% per session against ${overall.mean_signed_return_pct}% overall.` });
  return alerts;
}

export const shadowRules = { minimumSessions: 60, minimumMeanGain: 0.01, promoteT: 1.28, rejectT: -0.5 };
// Forward test of a stored parameter set against the tilt the live model actually published for the same sessions.
export function judgeParamSet(rows: Array<{ session_date: string; return_pct: number; live_tilt: string; shadow_tilt: string }>) {
  const sessions = new Map<string, number>();
  for (const row of rows) sessions.set(row.session_date, (sessions.get(row.session_date) ?? 0) + (tiltSign(row.shadow_tilt) - tiltSign(row.live_tilt)) * row.return_pct);
  const diffs = [...sessions.values()];
  const t = tStat(diffs), gain = mean(diffs) ?? 0;
  const status = diffs.length < shadowRules.minimumSessions ? 'shadow' : gain >= shadowRules.minimumMeanGain && t !== null && t >= shadowRules.promoteT ? 'promoted' : gain <= 0 && (t === null || t <= shadowRules.rejectT) ? 'rejected' : 'shadow';
  return { status, sessions: diffs.length, mean_gain_pct: round(gain), paired_t: t === null ? null : round(t, 2), minimum_sessions: shadowRules.minimumSessions };
}
