import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pulseModel, pulseTime } from '../../backend/src/market-pulse.ts';
import { token } from '../monitor/publish.mjs';

const args = {};
for (const arg of process.argv.slice(2)) {
  const match = /^--(session|out)=(.+)$/.exec(arg);
  if (!match || args[match[1]]) throw new Error('Usage: outlook.mjs --session=YYYY-MM-DD [--out=directory]');
  args[match[1]] = match[2];
}
if (!/^\d{4}-\d{2}-\d{2}$/.test(args.session ?? '')) throw new Error('Choose a future US session date');
const target = new Date(`${args.session}T12:00:00Z`);
if (!Number.isFinite(+target) || target.toISOString().slice(0, 10) !== args.session || [0, 6].includes(target.getUTCDay())) throw new Error('Session must be a valid weekday; check exchange holidays separately');
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
if (new URL(origin).protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(new URL(origin).hostname)) throw new Error('HTTPS required');
const auth = `Bearer ${await token()}`;
const responses = {};
for (const symbol of pulseModel.symbols) {
  const url = new URL('/v1/market-pulse/snapshot', origin);
  url.searchParams.set('symbol', symbol);
  const response = await fetch(url, { headers: { Authorization: auth }, signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw new Error(`Snapshot ${symbol} HTTP ${response.status}`);
  const snapshot = await response.json();
  if (!snapshot || snapshot.pulse?.symbol !== symbol || !snapshot.inputs || !snapshot.model || !snapshot.as_of) throw new Error(`Incomplete ${symbol} snapshot response`);
  pulseTime(snapshot.as_of);
  responses[symbol] = snapshot;
}
const asOf = responses[pulseModel.symbols[0]].as_of;
const cutoff = pulseTime(asOf);
const localDate = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(cutoff));
if (args.session <= localDate) throw new Error('Choose a target session after the captured live snapshot');
const modelHash = createHash('sha256').update(await readFile(new URL('../../backend/src/market-pulse.ts', import.meta.url))).digest('hex');
const inputHashes = Object.fromEntries(Object.entries(responses).map(([symbol, snapshot]) => [symbol,
  createHash('sha256').update(JSON.stringify(snapshot.inputs)).digest('hex')]));
const responseHashes = Object.fromEntries(Object.entries(responses).map(([symbol, snapshot]) => [symbol,
  createHash('sha256').update(JSON.stringify(snapshot)).digest('hex')]));
const report = { created_at: new Date().toISOString(), as_of: asOf, target_session: args.session, timezone: 'America/New_York',
  source: origin, model_sha256: modelHash, input_sha256: inputHashes, response_sha256: responseHashes,
  evaluation: 'Frozen live snapshot for a future session. No target-session outcome is included and this record makes no claim that the outlook predicted that outcome.',
  snapshots: Object.fromEntries(Object.entries(responses).map(([symbol, snapshot]) => [symbol, {
    file: `snapshot-${symbol}.json`, created_at: snapshot.created_at, as_of: snapshot.as_of, score: snapshot.pulse.score,
    outlook: snapshot.pulse.outlook, status: snapshot.pulse.status, confidence: snapshot.pulse.confidence,
  }])) };
const out = resolve(args.out ?? `.build-market-pulse/outlook-${args.session}-${cutoff}`);
await mkdir(out, { recursive: true });
for (const [symbol, snapshot] of Object.entries(responses)) {
  await writeFile(join(out, `snapshot-${symbol}.json`), JSON.stringify(snapshot, null, 2) + '\n', { flag: 'wx' });
}
await writeFile(join(out, 'outlook.json'), JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
const rows = Object.entries(responses).map(([symbol, snapshot]) => `| ${symbol} | ${snapshot.pulse.score ?? 'Withheld'} | ${snapshot.pulse.outlook} (${snapshot.pulse.status}) | ${snapshot.pulse.confidence} |`);
const lines = [`# Market outlook for ${args.session}`, '', `Captured live at ${asOf} (${new Date(cutoff).toLocaleString('en-US', { timeZone: 'America/New_York' })} Eastern).`, '', report.evaluation, '',
  '| Profile | Score | Outlook | Confidence |', '|---|---:|---|---|', ...rows, '',
  'Each immutable `snapshot-*.json` file contains the complete authenticated endpoint response, including the pulse, explanation, inputs and model metadata.',
  `Model source SHA-256: ${modelHash}.`, '', '| Profile | Input SHA-256 | Response SHA-256 |', '|---|---|---|',
  ...Object.keys(responses).map(symbol => `| ${symbol} | ${inputHashes[symbol]} | ${responseHashes[symbol]} |`), ''];
await writeFile(join(out, 'outlook.md'), lines.join('\n'), { flag: 'wx' });
console.log(JSON.stringify({ report: join(out, 'outlook.md'), as_of: asOf, target: args.session,
  snapshots: Object.entries(responses).map(([symbol, snapshot]) => ({ symbol, score: snapshot.pulse.score, outlook: snapshot.pulse.outlook, status: snapshot.pulse.status })) }, null, 2));
