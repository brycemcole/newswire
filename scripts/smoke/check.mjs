import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { connect } from 'node:http2';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { token } from '../monitor/publish.mjs';
import { credentials, devices, send } from '../monitor/apns.mjs';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const stateFile = join(homedir(), '.config', 'newswire', 'smoke-state.json');
const hosts = { sandbox: 'https://api.sandbox.push.apple.com', production: 'https://api.push.apple.com' };

// The same requests the app makes on launch, the home outlook and the Research screen.
export const checks = [
  { name: 'Feed', path: '/v1/stories?limit=50', valid: body => Array.isArray(body.stories) && body.stories.length > 0 },
  ...['SPY', 'QQQ', 'XLE', 'DAL'].map(symbol => ({ name: `Outlook ${symbol}`, path: `/v1/market-pulse?symbol=${symbol}&history=12`,
    valid: body => body.symbol === symbol && typeof body.status === 'string' && Array.isArray(body.history) })),
  ...['SPY', 'QQQ'].map(symbol => ({ name: `Research ${symbol}`, path: `/v1/research?symbol=${symbol}`,
    valid: body => body.symbol === symbol && body.performance && Array.isArray(body.agent?.board) && Array.isArray(body.agent?.questions) })),
];

export async function run(fetchImpl = fetch) {
  const bearer = await token();
  const results = [];
  for (const check of checks) {
    const started = Date.now();
    try {
      const response = await fetchImpl(new URL(check.path, origin), { headers: { Authorization: `Bearer ${bearer}`, Accept: 'application/json' }, signal: AbortSignal.timeout(20000) });
      const body = await response.json().catch(() => null);
      const ms = Date.now() - started;
      const error = !response.ok ? `HTTP ${response.status}${body?.error?.message ? `: ${body.error.message}` : ''}` : !body || !check.valid(body) ? 'unexpected response shape' : ms > 10000 ? `slow: ${ms} ms` : null;
      results.push({ name: check.name, ok: !error, ms, ...(error ? { error } : {}) });
    } catch (error) {
      results.push({ name: check.name, ok: false, ms: Date.now() - started, error: error.name === 'TimeoutError' ? 'timed out after 20 s' : error.message });
    }
  }
  return results;
}

async function alert(title, body) {
  const bearer = await token();
  const jwt = await credentials();
  const targets = await devices(bearer);
  for (const [environment, host] of Object.entries(hosts)) {
    const group = targets.filter(device => device.environment === environment);
    if (!group.length) continue;
    const client = connect(host);
    await Promise.all(group.map(device => send(client, jwt, device, { aps: { alert: { title, body }, sound: 'default' } })));
    client.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const results = await run();
  const failed = results.filter(result => !result.ok);
  console.log(JSON.stringify({ at: new Date().toISOString(), failed: failed.length, results }));
  if (!process.argv.includes('--no-alert')) {
    const previous = JSON.parse(await readFile(stateFile, 'utf8').catch(() => '{"failing":[]}'));
    const failing = failed.map(result => result.name);
    // Alert on a change of state only, so an ongoing outage sends one push rather than one every five minutes.
    if (failing.join('|') !== previous.failing.join('|')) {
      if (failing.length) await alert('Newswire is failing', failed.map(result => `${result.name}: ${result.error}`).join('\n').slice(0, 400)).catch(error => console.error(`alert failed: ${error.message}`));
      else await alert('Newswire recovered', 'All app requests are working again.').catch(error => console.error(`alert failed: ${error.message}`));
    }
    await mkdir(join(homedir(), '.config', 'newswire'), { recursive: true, mode: 0o700 });
    await writeFile(`${stateFile}.tmp`, JSON.stringify({ failing, at: new Date().toISOString() }), { mode: 0o600 });
    await rename(`${stateFile}.tmp`, stateFile);
  }
  if (failed.length) process.exitCode = 1;
}
