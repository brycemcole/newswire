import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { calculatePulse, pulseModel, pulseTime } from '../../backend/src/market-pulse.ts';
import { token } from '../monitor/publish.mjs';
import { priceComparison, fetchPrices } from './prices.mjs';

const args = {};
for (const arg of process.argv.slice(2)) {
  const match = /^--(as-of|stories|prices|out)=(.+)$/.exec(arg);
  if (!match || args[match[1]]) throw new Error('Usage: node --experimental-strip-types scripts/market-pulse/replay.mjs --as-of=ISO_WITH_ZONE [--stories=archive.json] [--prices=prices.json] [--out=directory]');
  args[match[1]] = match[2];
}
if (!args['as-of']) throw new Error('--as-of is required; include an explicit timezone');
const cutoff = pulseTime(args['as-of']);
if (cutoff > Date.now()) throw new Error('Cannot replay a future cutoff');
const asOf = new Date(cutoff).toISOString();
const out = resolve(args.out ?? '.build-market-pulse/replay');
await mkdir(out, { recursive: true });
const modelHash = createHash('sha256').update(await readFile(new URL('../../backend/src/market-pulse.ts', import.meta.url))).digest('hex');
let archive;
if (args.stories) archive = JSON.parse(await readFile(args.stories, 'utf8'));
else {
  const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
  const originURL = new URL(origin);
  if (originURL.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(originURL.hostname)) throw new Error('HTTPS required');
  const since = new Date(cutoff - (pulseModel.windowHours + 72) * 3600000).toISOString();
  const stories = []; let cursor; let pages = 0;
  do {
    const url = new URL('/v1/stories', origin);
    for (const [key, value] of Object.entries({ limit: '100', since, until: new Date().toISOString(), retracted: 'include', ...(cursor ? { cursor } : {}) })) url.searchParams.set(key, value);
    const response = await fetch(url, { headers: { Authorization: `Bearer ${await token()}` }, signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error(`News archive HTTP ${response.status}`);
    const payload = await response.json();
    stories.push(...payload.stories); cursor = payload.next_cursor;
    if (++pages >= 100 && cursor) throw new Error('Archive pagination cap reached; refusing partial replay');
  } while (cursor);
  archive = { retrieved_at: new Date().toISOString(), origin, coverage_start: since, stories };
}
if (!Array.isArray(archive.stories)) throw new Error('Invalid stories archive');
const prices = args.prices ? JSON.parse(await readFile(args.prices, 'utf8')) : await fetchPrices(asOf, [...pulseModel.symbols, 'CL=F']);
const coverageStart = Date.parse(archive.coverage_start);
const incompleteAt = time => !Number.isFinite(coverageStart) || coverageStart > time - pulseModel.windowHours * 3600000;
const snapshots = pulseModel.symbols.map(symbol => calculatePulse(archive.stories, asOf, symbol, incompleteAt(cutoff)));
const outcomes = Object.fromEntries([...pulseModel.symbols, 'CL=F'].map(symbol => [symbol, priceComparison(prices[symbol], asOf)]));
const first = Math.min(...archive.stories.map(s => Date.parse(s.received_at)).filter(Number.isFinite));
const timeline = [];
const stop = Math.min(Date.parse(archive.retrieved_at), Date.now());
const start = Math.max(cutoff - 72 * 3600000, first);
const times = new Set([cutoff]);
for (let time = Math.ceil(start / 3600000) * 3600000; time <= stop; time += 3600000) times.add(time);
for (const s of archive.stories) { const time = Math.max(Date.parse(s.received_at), Date.parse(s.published_at)); if (time >= start && time <= stop) times.add(time); }
for (const time of [...times].sort((a, b) => a - b)) {
  const p = calculatePulse(archive.stories, new Date(time).toISOString(), 'SPY', incompleteAt(time));
  timeline.push({ as_of: p.as_of, score: p.score, research_score: p.research_score, status: p.status, headline_age_hours: p.coverage.headline_age_hours, matched_stories: p.coverage.matched_stories });
}
const report = { generated_at: new Date().toISOString(), as_of: asOf, model: pulseModel, model_sha256: modelHash,
  evaluation: 'Single-session retrospective case study; current hand-written rules were developed after the outcome. This is not an out-of-sample predictive backtest.',
  archive: { retrieved_at: archive.retrieved_at, source: archive.origin, coverage_start: archive.coverage_start ?? null, stories: archive.stories.length,
    sha256: createHash('sha256').update(JSON.stringify(archive.stories)).digest('hex') },
  timeline_note: 'Snapshots whose full 96-hour window is not covered by the archive are marked incomplete and withhold scores. Snapshots include hourly decay and each story arrival.',
  snapshots, outcomes, timeline };
await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
await writeFile(join(out, 'timeline.csv'), 'as_of,score,research_score,status,headline_age_hours,matched_stories\n' + timeline.map(p => [p.as_of, p.score ?? '', p.research_score ?? '', p.status, p.headline_age_hours ?? '', p.matched_stories].join(',')).join('\n') + '\n');
await writeFile(join(out, 'stories.json'), JSON.stringify(archive, null, 2) + '\n');
await writeFile(join(out, 'prices.json'), JSON.stringify(prices, null, 2) + '\n');
const fmt = n => n === null || n === undefined ? 'Unavailable' : `${n >= 0 ? '+' : ''}${n.toFixed(2)}%`;
const lines = [`# Market Pulse replay — ${asOf}`, '', report.evaluation, '',
  'Scores use only immutable wire titles received and published by the cutoff. Later retractions do not erase what was known then. Prices never enter the news calculation.', '',
  '| Exposure | Published score | Research calculation | Coverage |', '|---|---:|---:|---|',
  ...snapshots.map(p => `| ${p.symbol} | ${p.score ?? 'Withheld'} | ${p.research_score ?? 'No signal'} | ${p.status} |`), '',
  `Last available publisher/X headline: ${snapshots[0].coverage.latest_headline_at}; age ${snapshots[0].coverage.headline_age_hours} hours.`,
  `${snapshots[0].coverage.eligible_stories} eligible stories; ${snapshots[0].coverage.headline_stories} headlines; ${snapshots[0].coverage.matched_stories} recognized by conservative macro rules. Unmatched does not mean neutral.`, '',
  '## Evidence at the cutoff', '',
  ...snapshots[0].factors.flatMap(f => [`- **${f.factor}: ${f.points} points**`, ...f.evidence.map(e => `  - [${e.title.replaceAll('[', '').replaceAll(']', '')}](${e.url}) — ${e.source}, received ${e.received_at}. ${e.reason}.`)]), '',
  '## Price comparison', '',
  'Retrospectively downloaded Yahoo 5-minute bars. At-cutoff prices use only completed bars, no more than 15 minutes old. These are not proof of live quote availability at the time. Crude comparisons use the US equity clock, not exchange settlement.', '',
  '| Symbol | Before cutoff, vs prior 4 p.m. | Cutoff → 4 p.m. | 9:30 a.m. → 4 p.m. | Prior 4 p.m. → 4 p.m. | Worst after cutoff |',
  '|---|---:|---:|---:|---:|---:|',
  ...Object.entries(outcomes).map(([s, o]) => `| ${s} | ${fmt(o.pre_cutoff_change_pct)} | ${fmt(o.cutoff_to_close_pct)} | ${fmt(o.open_to_close_pct)} | ${fmt(o.prior_close_to_close_pct)} | ${fmt(o.worst_after_cutoff_pct)} |`), '',
  '## Reproducibility and limitations', '',
  `- Model: ${pulseModel.version}; SHA-256 ${modelHash}.`,
  '- Fixed, uncalibrated factor budgets: energy 12, trade 10, rates 10, growth 8, credit 10 points; 36-hour half-life; 96-hour news window.',
  '- Repeated coverage is capped by factor and event group. Opposing evidence offsets; repeated headlines do not reset event age.',
  '- Coverage older than 24 hours withholds the score; this is a feed-freshness warning, not an inference that the market is neutral.',
  '- The score is macro exposure only, including for DAL; it is not a complete stock forecast. No company earnings or valuation model.',
  '- One chosen day, inspected after its outcome, cannot establish accuracy or an edge. Freeze rules and collect forward snapshots before performance claims.',
  '- report.json contains exact inputs used per factor and a timeline; stories.json and prices.json preserve source data. timeline.csv includes hourly and arrival-driven recalculation.', ''];
await writeFile(join(out, 'report.md'), lines.join('\n'));
console.log(JSON.stringify({ report: join(out, 'report.md'), as_of: asOf, snapshots: snapshots.map(({ symbol, score, research_score, status, coverage }) => ({ symbol, score, research_score, status, coverage })), outcomes }, null, 2));
