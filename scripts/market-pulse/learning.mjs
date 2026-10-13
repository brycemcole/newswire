import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { chronologicalSplit, trainLogistic, brierScore, calibrationBins, predictCandidate, promotionGate } from '../../backend/src/forecast-model.ts';
import { token } from '../monitor/publish.mjs';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const symbols = ['SPY', 'QQQ'];
const horizons = ['opening_gap', 'cutoff_to_open', 'open_to_close'];

export function evaluateLearning(rows, symbol, horizon) {
  const usable = rows.filter(r => r.symbol === symbol && r.horizon === horizon && Number.isFinite(r.direction) && r.direction !== 0 && r.features && r.tilt !== 'unavailable')
    .sort((a, b) => a.session_date.localeCompare(b.session_date));
  const split = chronologicalSplit(usable, row => row.session_date);
  const train = split.train.map(row => ({ features: row.features, outcome: row.direction > 0 ? 1 : 0 }));
  if (split.sessionCounts.train < 180 || split.sessionCounts.calibration < 60 || split.sessionCounts.test < 60)
    return { status: 'shadow', eligible: false, symbol, horizon, reason: 'insufficient chronological train/calibration/test support', support: split.sessionCounts };
  const model = trainLogistic(train, Object.keys(train[0].features), 0.2);
  const priceKeys = ['market_points', 'market_available', 'market_coverage'];
  const priceModel = trainLogistic(train, priceKeys, 0.2);
  const fitCalibrator = predictor => {
    const calibrationRows = split.calibration.map(row => ({ probability: predictor(row.features), outcome: row.direction > 0 ? 1 : 0 }));
    let a = 1, b = 0;
    for (let step = 0; step < 1200; step++) {
      let ga = 0, gb = 0;
      for (const row of calibrationRows) {
        const clipped = Math.max(1e-6, Math.min(1 - 1e-6, row.probability)), x = Math.log(clipped / (1 - clipped));
        const p = 1 / (1 + Math.exp(-Math.max(-30, Math.min(30, a * x + b))));
        const error = p - row.outcome; ga += error * x; gb += error;
      }
      a -= 0.02 * ga / calibrationRows.length; b -= 0.02 * gb / calibrationRows.length;
    }
    return { slope: a, intercept: b };
  };
  const coefficients = { intercept: model.intercept, weights: model.weights, means: model.means, scales: model.scales };
  const priceCoefficients = { intercept: priceModel.intercept, weights: priceModel.weights, means: priceModel.means, scales: priceModel.scales };
  const fullCalibrator = fitCalibrator(features => model.predict(features));
  const priceCalibrator = fitCalibrator(features => priceModel.predict(features));
  const candidate = { coefficients, calibrator: fullCalibrator };
  const priceOnly = { coefficients: priceCoefficients, calibrator: priceCalibrator };
  const test = split.test.map(row => ({ probability: predictCandidate(candidate, row.features), outcome: row.direction > 0 ? 1 : 0 }));
  const baselineUpProbability = Math.max(0.01, Math.min(0.99, train.filter(r => r.outcome === 1).length / train.length));
  const baseline = test.map(row => ({ probability: baselineUpProbability, outcome: row.outcome }));
  const priceTest = split.test.map(row => ({ probability: predictCandidate(priceOnly, row.features), outcome: row.direction > 0 ? 1 : 0 }));
  const historicalGate = promotionGate({ trainSessions: split.sessionCounts.train, calibrationSessions: split.sessionCounts.calibration,
    testSessions: split.sessionCounts.test, candidateBrier: brierScore(test), baselineBrier: brierScore(baseline), priceOnlyBrier: brierScore(priceTest), bins: calibrationBins(test) });
  const trainingRows = split.train;
  const trainingHash = createHash('sha256').update(JSON.stringify(trainingRows)).digest('hex');
  return { status: 'shadow', eligible: false, symbol, horizon, historicalGate, support: split.sessionCounts, baselineUpProbability, trainingHash,
    trainThrough: trainingRows.at(-1)?.session_date ?? null, candidate, priceOnly, evaluation: { historical_test_brier: brierScore(test), baseline_brier: brierScore(baseline), price_only_brier: brierScore(priceTest),
      calibration_bins: calibrationBins(test), gate: historicalGate, note: 'Historical holdout is diagnostic only. Promotion requires prospective candidate predictions and outcomes.' } };
}

async function request(path, method = 'GET', body) {
  const url = new URL(path, origin);
  if (url.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(url.hostname)) throw new Error('HTTPS required');
  const response = await fetch(url, { method, headers: { Authorization: `Bearer ${await token()}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(30000) });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${path} HTTP ${response.status}: ${payload.error?.message ?? 'request failed'}`);
  return payload;
}

export async function syncLearning(now = Date.now()) {
  const actions = [];
  for (const symbol of symbols) for (const horizon of horizons) {
    const query = new URLSearchParams({ symbol, horizon });
    const [training, candidates] = await Promise.all([
      request(`/v1/research/training?${query}`), request(`/v1/research/candidates?${query}`),
    ]);
    const rows = training.rows ?? [];
    const result = evaluateLearning(rows, symbol, horizon);
    const list = candidates.candidates ?? [];
    const month = new Date(now).toISOString().slice(0, 7);
    const latestThisMonth = list.some(candidate => String(candidate.created_at ?? '').slice(0, 7) === month);
    if (result.candidate && !latestThisMonth) {
      const payload = { symbol, horizon, coefficients: result.candidate.coefficients, calibrator: result.candidate.calibrator, priceOnly: result.priceOnly,
        evaluation: { ...result.evaluation, support: result.support }, baselineUpProbability: result.baselineUpProbability,
        trainThrough: result.trainThrough, trainingHash: result.trainingHash };
      actions.push({ symbol, horizon, registered: await request('/v1/research/candidates', 'POST', payload) });
    } else actions.push({ symbol, horizon, candidate: null, reason: result.reason ?? (latestThisMonth ? 'monthly candidate limit already reached' : 'no eligible candidate') });
    for (const candidate of list.filter(row => row.status === 'shadow' || row.status === 'promoted').slice(0, 10)) {
      actions.push({ symbol, horizon, evaluated: await request('/v1/research/candidates/evaluate', 'POST', { candidate_id: candidate.id }) });
    }
  }
  return actions;
}

if (process.argv[1]?.endsWith('/learning.mjs')) {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === '--sync') console.log(JSON.stringify(await syncLearning(), null, 2));
  else {
    const [path, symbol, horizon, output] = args;
    if (!path || !['SPY', 'QQQ'].includes(symbol) || !horizons.includes(horizon))
      throw new Error('Usage: learning.mjs --sync | rows.json SPY|QQQ opening_gap|cutoff_to_open|open_to_close [output.json]');
    const result = evaluateLearning(JSON.parse(await readFile(path, 'utf8')), symbol, horizon);
    if (output) await writeFile(output, JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result, null, 2));
  }
}
