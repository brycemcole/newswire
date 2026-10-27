export const forecastModel = {
  version: 'forecast-tilt-v2',
  horizons: ['opening_gap', 'cutoff_to_open', 'open_to_close'] as const,
  symbols: ['SPY', 'QQQ'] as const,
  probabilities: null,
  candidate: { version: 'ridge-logit-shadow-v2', minimumTrainSessions: 180, minimumCalibrationSessions: 60,
    minimumTestSessions: 60, gapSessions: 5, promotionMinimumSessions: 250, maximumBrier: 0.24,
    minimumBrierImprovement: 0.01, minimumCalibrationBins: 5, maximumCalibrationError: 0.08 },
} as const;

export type Horizon = typeof forecastModel.horizons[number];
export type Features = Record<string, number>;

const clamp = (x: number, low: number, high: number) => Math.max(low, Math.min(high, x));
const sigmoid = (x: number) => 1 / (1 + Math.exp(-clamp(x, -30, 30)));

export const marketGroups: Record<string, string[]> = {
  futures_points: ['futures', 'nasdaq', 'smallcaps', 'premarket'],
  rates_points: ['yield', 'front_yield', 'real_yield', 'credit', 'dollar', 'yen'],
  volatility_points: ['vix', 'vix_term', 'vix_short'],
  breadth_points: ['breadth', 'semis'],
  overseas_points: ['europe', 'germany', 'asia', 'china'],
  commodity_points: ['oil', 'copper', 'gold', 'bitcoin'],
};
const eventShrink = 0.4;
export const marketGroupKeys = [...Object.keys(marketGroups), 'market_other_points'];

function marketFeatures(market: any, available: boolean): Features {
  const inputs: any[] = Array.isArray(market?.inputs) ? market.inputs : [];
  const groups: Features = Object.fromEntries(Object.entries(marketGroups).map(([key, ids]) => [key, available
    ? inputs.filter(input => input?.status === 'live' && ids.includes(input.id)).reduce((sum, input) => sum + (Number(input.points) || 0), 0) / 40
    : 0]));
  const total = available ? Number(market.points ?? 0) / 40 : 0;
  return { ...groups, market_other_points: available ? total - Object.values(groups).reduce((sum, value) => sum + value, 0) : 0 };
}

// High-impact release due, monthly option expiry or quarter-end: the score shrinks toward neutral instead of calling a direction.
export function eventRisk(pulse: any): number {
  const high = Array.isArray(pulse?.components?.calendar?.upcoming) && pulse.components.calendar.upcoming.some((event: any) => event?.high) ? 1 : 0;
  const at = new Date(pulse?.as_of ?? NaN);
  if (!Number.isFinite(+at)) return high;
  const day = at.getUTCDate(), weekday = at.getUTCDay(), month = at.getUTCMonth();
  const opex = weekday === 5 && day >= 15 && day <= 21 ? 0.5 : 0;
  const lastDay = new Date(Date.UTC(at.getUTCFullYear(), month + 1, 0)).getUTCDate();
  const quarterEnd = month % 3 === 2 && day >= lastDay - 2 ? 0.5 : 0;
  return Math.max(high, opex, quarterEnd);
}

export function makeFeatures(snapshot: any): Features {
  const pulse = snapshot?.pulse ?? {};
  const market = pulse.components?.market;
  const news = pulse.components?.news;
  const calendar = pulse.components?.calendar;
  const valid = pulse.status === 'available';
  const score = valid ? (Number.isFinite(pulse.research_score) ? pulse.research_score : pulse.score) : null;
  const marketOn = valid && market?.status === 'available';
  return {
    ...marketFeatures(market, marketOn),
    score_delta: Number.isFinite(score) ? (score - 50) / 50 : 0,
    score_available: Number.isFinite(score) ? 1 : 0,
    news_points: valid && news?.status === 'available' ? Number(news.points ?? 0) / 25 : 0,
    news_available: valid && news?.status === 'available' ? 1 : 0,
    market_points: marketOn ? Number(market.points ?? 0) / 40 : 0,
    market_available: marketOn ? 1 : 0,
    earnings_points: Number(pulse.components?.earnings?.points ?? 0) / 10,
    calendar_points: Number(calendar?.points ?? 0) / 10,
    event_risk: eventRisk(pulse),
    story_count: Math.log1p(Math.max(0, Number(pulse.coverage?.headline_stories ?? 0))) / 5,
    market_coverage: Math.max(0, Math.min(1, Number(market?.live_inputs ?? 0) / 24)),
  };
}

export function forecastTilt(features: Features): { score: number | null; tilt: 'up' | 'down' | 'neutral' | 'unavailable'; probabilities: null } {
  const available = features.score_available || features.news_available || features.market_available;
  if (!available) return { score: null, tilt: 'unavailable', probabilities: null };
  const hasGroups = marketGroupKeys.some(key => key in features);
  const marketPoints = hasGroups ? marketGroupKeys.reduce((sum, key) => sum + (features[key] ?? 0), 0) : (features.market_points ?? 0);
  const raw = 50 + 25 * (features.news_points ?? 0) + 40 * marketPoints + 10 * (features.calendar_points ?? 0) + 10 * (features.earnings_points ?? 0);
  const shrunk = 50 + (raw - 50) * (1 - eventShrink * clamp(features.event_risk ?? 0, 0, 1));
  const score = Math.max(0, Math.min(100, Math.round(shrunk * 100) / 100));
  const tilt = score >= 55 ? 'up' : score <= 45 ? 'down' : 'neutral';
  return { score, tilt, probabilities: null };
}

export function brierScore(rows: Array<{ probability: number; outcome: number }>): number | null {
  if (!rows.length) return null;
  return rows.reduce((sum, row) => sum + (row.probability - row.outcome) ** 2, 0) / rows.length;
}

export function calibrationBins(rows: Array<{ probability: number; outcome: number }>, bins = 5) {
  return Array.from({ length: bins }, (_, i) => {
    const low = i / bins, high = (i + 1) / bins;
    const group = rows.filter(row => row.probability >= low && (i === bins - 1 ? row.probability <= high : row.probability < high));
    return { low, high, count: group.length, predicted: group.length ? group.reduce((s, r) => s + r.probability, 0) / group.length : null,
      observed: group.length ? group.reduce((s, r) => s + r.outcome, 0) / group.length : null };
  });
}

export function promotionGate({ trainSessions, calibrationSessions, testSessions, candidateBrier, baselineBrier, priceOnlyBrier, bins }: {
  trainSessions: number; calibrationSessions: number; testSessions: number; candidateBrier: number | null;
  baselineBrier: number | null; priceOnlyBrier: number | null; bins: Array<{ count: number; predicted: number | null; observed: number | null }>;
}) {
  const rules = forecastModel.candidate;
  const supported = trainSessions >= rules.minimumTrainSessions && calibrationSessions >= rules.minimumCalibrationSessions && testSessions >= rules.minimumTestSessions;
  const populated = bins.filter(bin => bin.count >= 10 && bin.predicted !== null && bin.observed !== null);
  const calibrationError = populated.length ? populated.reduce((sum, bin) => sum + Math.abs(bin.predicted! - bin.observed!) * bin.count, 0) / populated.reduce((sum, bin) => sum + bin.count, 0) : null;
  const calibrated = populated.length >= rules.minimumCalibrationBins && calibrationError !== null && calibrationError <= rules.maximumCalibrationError;
  const beatsBaseline = candidateBrier !== null && baselineBrier !== null && candidateBrier <= rules.maximumBrier && candidateBrier <= baselineBrier - rules.minimumBrierImprovement;
  const beatsPriceOnly = candidateBrier !== null && priceOnlyBrier !== null && candidateBrier <= priceOnlyBrier - rules.minimumBrierImprovement;
  const eligible = supported && calibrated && beatsBaseline && beatsPriceOnly && testSessions >= rules.promotionMinimumSessions;
  return { eligible, supported, calibrated, beatsBaseline, beatsPriceOnly, minimumIndependentSessions: rules.promotionMinimumSessions,
    candidateBrier, baselineBrier, priceOnlyBrier, calibrationError, maximumCalibrationError: rules.maximumCalibrationError, reason: eligible ? 'all promotion gates passed' : !supported ? 'insufficient chronological train/calibration/test support' : !calibrated ? 'insufficient populated calibration bins' : !beatsBaseline ? 'candidate does not beat the price-only base-rate baseline' : 'promotion support threshold not met' };
}

export function trainLogistic(rows: Array<{ features: Features; outcome: number }>, keys = Object.keys(rows[0]?.features ?? []), lambda = 0.1) {
  const means = Object.fromEntries(keys.map(key => [key, rows.reduce((s, row) => s + (row.features[key] ?? 0), 0) / Math.max(1, rows.length)]));
  const scales = Object.fromEntries(keys.map(key => [key, Math.sqrt(rows.reduce((s, row) => s + ((row.features[key] ?? 0) - means[key]) ** 2, 0) / Math.max(1, rows.length)) || 1]));
  const weights = Object.fromEntries(keys.map(key => [key, 0])); let intercept = 0;
  for (let epoch = 0; epoch < 1200; epoch++) {
    const rate = 0.08 / Math.sqrt(1 + epoch / 100);
    let interceptGradient = 0; const gradients = Object.fromEntries(keys.map(key => [key, 0]));
    for (const row of rows) {
      const x = Object.fromEntries(keys.map(key => [key, ((row.features[key] ?? 0) - means[key]) / scales[key]]));
      const error = sigmoid(intercept + keys.reduce((s, key) => s + weights[key] * x[key], 0)) - row.outcome;
      interceptGradient += error;
      for (const key of keys) gradients[key] += error * x[key];
    }
    intercept -= rate * interceptGradient / Math.max(1, rows.length);
    for (const key of keys) weights[key] -= rate * (gradients[key] / Math.max(1, rows.length) + lambda * weights[key]);
  }
  return { intercept, weights, means, scales, predict(features: Features) { return sigmoid(intercept + keys.reduce((s, key) => s + weights[key] * ((features[key] ?? 0) - means[key]) / scales[key], 0)); } };
}

export function chronologicalSplit<T>(rows: T[], sessionOf: (row: T) => string, train = 0.6, calibration = 0.2, gap = 5) {
  const sessions = [...new Set(rows.map(sessionOf))].sort();
  const trainEnd = Math.floor(sessions.length * train), calibrationEnd = Math.floor(sessions.length * (train + calibration));
  const trainSessions = new Set(sessions.slice(0, Math.max(0, trainEnd - gap)));
  const calibrationSessions = new Set(sessions.slice(Math.min(sessions.length, trainEnd + gap), Math.max(trainEnd + gap, calibrationEnd - gap)));
  const testSessions = new Set(sessions.slice(Math.min(sessions.length, calibrationEnd + gap)));
  return { train: rows.filter(r => trainSessions.has(sessionOf(r))), calibration: rows.filter(r => calibrationSessions.has(sessionOf(r))), test: rows.filter(r => testSessions.has(sessionOf(r))),
    sessionCounts: { train: trainSessions.size, calibration: calibrationSessions.size, test: testSessions.size, gaps: sessions.length - trainSessions.size - calibrationSessions.size - testSessions.size } };
}

export function predictCandidate(candidate: any, features: Features): number | null {
  const model = candidate?.coefficients ?? candidate;
  if (!model || !Number.isFinite(model.intercept) || !model.weights || !model.means || !model.scales) return null;
  const calibrator = candidate?.calibrator ?? { slope: 1, intercept: 0 };
  const keys = Object.keys(model.weights);
  const raw = sigmoid(model.intercept + keys.reduce((sum, key) => sum + model.weights[key] * ((features[key] ?? 0) - model.means[key]) / (model.scales[key] || 1), 0));
  const clipped = clamp(raw, 1e-6, 1 - 1e-6);
  return sigmoid(Number(calibrator.slope ?? 1) * Math.log(clipped / (1 - clipped)) + Number(calibrator.intercept ?? 0));
}
