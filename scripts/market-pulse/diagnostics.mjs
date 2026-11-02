import { mkdir, writeFile } from 'node:fs/promises';
import { connect } from 'node:http2';
import { credentials, devices, send } from '../monitor/apns.mjs';
import { token } from '../monitor/publish.mjs';
import { loadModule } from './load-model.mjs';

const diag = await loadModule('src/forecast-diagnostics.ts');
const { defaultTilt } = await loadModule('src/forecast-model.ts');
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const hosts = { sandbox: 'https://api.sandbox.push.apple.com', production: 'https://api.push.apple.com' };
const symbols = ['SPY', 'QQQ'];
const horizons = ['opening_gap', 'cutoff_to_open', 'open_to_close'];

async function request(path, method = 'GET', body) {
  const url = new URL(path, origin);
  if (url.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(url.hostname)) throw new Error('HTTPS required');
  const response = await fetch(url, { method, headers: { Authorization: `Bearer ${await token()}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(60000) });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${path} HTTP ${response.status}: ${payload.error?.message ?? 'request failed'}`);
  return payload;
}

async function notify(title, body) {
  const bearer = await token(), jwt = await credentials(), targets = await devices(bearer);
  for (const [environment, host] of Object.entries(hosts)) {
    const group = targets.filter(device => device.environment === environment);
    if (!group.length) continue;
    const client = connect(host);
    await Promise.all(group.map(device => send(client, jwt, device, { aps: { alert: { title, body }, sound: 'default' } })));
    client.close();
  }
}

export async function runDiagnostics({ push = true, now = Date.now() } = {}) {
  const month = new Date(now).toISOString().slice(0, 7), results = [], alerts = [];
  for (const symbol of symbols) for (const horizon of horizons) {
    const query = new URLSearchParams({ symbol, horizon });
    const [data, previous, sets] = await Promise.all([request(`/v1/research/diagnostics?${query}`), request(`/v1/research/reports?${query}&kind=weekly_diagnostics&limit=1`), request(`/v1/research/param-sets?${query}`)]);
    const forecasts = data.forecasts;
    const promoted = sets.param_sets.find(set => set.status === 'promoted');
    const live = promoted ? JSON.parse(promoted.params_json) : defaultTilt;
    const misses = diag.missReport(forecasts, live), channels = diag.channelDiagnostics(forecasts, data.impacts), calibration = diag.calibrationMap(forecasts), tuning = diag.tuneTilt(forecasts, live);
    const drift = diag.driftAlerts(misses, channels, previous.reports[0]?.report);
    const actions = [];
    if (tuning.proposal && !sets.param_sets.some(set => set.created_at.slice(0, 7) === month))
      actions.push({ registered: await request('/v1/research/param-sets', 'POST', { symbol, horizon, params: tuning.proposal, evaluation: { tuning, live }, trainThrough: tuning.train_through }) });
    for (const set of sets.param_sets.filter(item => item.status === 'shadow' || item.status === 'promoted'))
      actions.push({ evaluated: await request('/v1/research/param-sets/evaluate', 'POST', { param_set_id: set.id }) });
    const report = { generated_at: new Date(now).toISOString(), symbol, horizon, live_params: live, impacts_truncated: data.impacts_truncated, ...misses, channels, calibration, tuning, drift, actions };
    await request('/v1/research/reports', 'POST', { kind: 'weekly_diagnostics', symbol, horizon, window_end: report.generated_at, report });
    results.push(report);
    alerts.push(...drift.map(item => ({ symbol, horizon, ...item })));
  }
  if (push && alerts.length) await notify('Newswire model drift', alerts.slice(0, 4).map(a => `${a.symbol} ${a.horizon}: ${a.detail}`).join('\n').slice(0, 400)).catch(error => console.error(`push failed: ${error.message}`));
  return { results, alerts };
}

export function markdown({ results, alerts }) {
  const pct = value => value === null || value === undefined ? 'n/a' : `${(value * 100).toFixed(0)}%`;
  const lines = [`# Model diagnostics ${results[0]?.generated_at ?? ''}`, '', alerts.length ? `## Alerts\n${alerts.map(a => `- ${a.symbol} ${a.horizon}: ${a.detail}`).join('\n')}` : '## Alerts\nNone.'];
  for (const r of results) {
    lines.push('', `## ${r.symbol} ${r.horizon}`, `${r.overall.sessions} settled sessions, ${r.overall.called} called. Hit ${pct(r.overall.hit_rate)} vs always-up ${pct(r.overall.always_up_hit_rate)} vs price-only ${pct(r.overall.price_only_hit_rate)}. Mean signed return ${r.overall.mean_signed_return_pct ?? 'n/a'}% (t ${r.overall.signed_return_t ?? 'n/a'}).`,
      `Terms: ${r.terms.filter(t => t.verdict !== 'insufficient').map(t => `${t.term} ${t.verdict}`).join(', ') || 'not enough data to judge any term'}.`,
      `Channels: ${r.channels.filter(c => c.recommendation !== 'insufficient').map(c => `${c.channel} ${c.recommendation}`).join(', ') || 'not enough data'}.`,
      `Tuning: ${r.tuning.status}${r.tuning.out_of_sample ? ` (out-of-sample gain ${r.tuning.out_of_sample.mean_gain_pct}%, t ${r.tuning.out_of_sample.paired_t})` : ''}.`);
    for (const w of r.worst.slice(0, 3)) lines.push(`- Miss ${w.session_date}: ${w.tilt} at ${w.score}, moved ${w.return_pct}%, misled by ${w.misled_by.map(m => m.term).join(', ') || 'n/a'}.`);
  }
  return lines.join('\n') + '\n';
}

if (process.argv[1]?.endsWith('/diagnostics.mjs')) {
  const outcome = await runDiagnostics({ push: !process.argv.includes('--no-push') });
  const text = markdown(outcome);
  if (process.argv.includes('--write')) {
    await mkdir(new URL('../../.build-market-pulse/learning/', import.meta.url), { recursive: true });
    await writeFile(new URL(`../../.build-market-pulse/learning/${new Date().toISOString().slice(0, 10)}.md`, import.meta.url), text);
  }
  console.log(text);
}
