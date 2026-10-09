import { createSign } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { connect } from 'node:http2';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { token } from './publish.mjs';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const directory = join(homedir(), '.config', 'newswire');
const hosts = { sandbox: 'https://api.sandbox.push.apple.com', production: 'https://api.push.apple.com' };

export async function credentials() {
  const config = JSON.parse(await readFile(join(directory, 'apns.json'), 'utf8').catch(() => '{}'));
  const keyId = process.env.APNS_KEY_ID ?? config.key_id;
  const teamId = process.env.APNS_TEAM_ID ?? config.team_id ?? 'A792L5W262';
  const key = await readFile(process.env.APNS_KEY_FILE ?? join(directory, 'apns-key.p8'), 'utf8').catch(() => '');
  if (!keyId || !key.trim()) throw new Error('APNs is not configured: add ~/.config/newswire/apns-key.p8 and key_id in apns.json');
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = `${encode({ alg: 'ES256', kid: keyId })}.${encode({ iss: teamId, iat: Math.floor(Date.now() / 1000) })}`;
  return `${unsigned}.${createSign('SHA256').update(unsigned).sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

export async function devices(bearer) {
  const response = await fetch(new URL('/v1/devices', origin), { headers: { Authorization: `Bearer ${bearer}` }, signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`devices ${response.status}`);
  return (await response.json()).devices;
}

export function send(client, jwt, device, payload, type = 'alert') {
  return new Promise(resolve => {
    const request = client.request({
      ':method': 'POST',
      ':path': `/3/device/${device.token}`,
      authorization: `bearer ${jwt}`,
      'apns-topic': process.env.APNS_TOPIC ?? 'com.brycecole.newswire',
      'apns-push-type': type,
      'apns-priority': type === 'background' ? '5' : '10',
    });
    let status = 0;
    let body = '';
    request.setTimeout(10000, () => request.close());
    request.on('response', headers => { status = headers[':status']; });
    request.on('data', chunk => { body += chunk; });
    request.on('close', () => resolve({ status, reason: body ? JSON.parse(body).reason : undefined }));
    request.on('error', error => resolve({ status: 0, reason: error.message }));
    request.end(JSON.stringify(payload));
  });
}

// Notification topics the app can mute, matched against story tags in order (global equities before US equities).
export const topics = [
  ['jobs', ['employment', 'jobs-report', 'jolts']],
  ['inflation', ['inflation', 'cpi', 'pce', 'ppi']],
  ['growth', ['gdp', 'growth', 'retail-sales']],
  ['fed', ['fed', 'monetary-policy', 'rates', 'yield-curve', 'credit', 'treasury', 'auction', 'housing']],
  ['global-markets', ['global', 'currencies']],
  ['us-markets', ['equities', 'volatility', 'commodities', 'energy']],
  ['crypto', ['crypto']],
  ['companies', ['earnings', 'insider', 'sec-filing', 'congress', 'stock-trades']],
  ['government', ['fiscal', 'debt', 'executive-order', 'regulation', 'defense', 'contracts']],
  ['world', ['shipping', 'chokepoints', 'earthquake', 'outage', 'cyber', 'aviation', 'trending']],
  ['headlines', ['headlines', 'x']],
];

export function topicFor(tags = []) {
  return topics.find(([, match]) => match.some(tag => tags.includes(tag)))?.[0] ?? 'headlines';
}

function muted(device, story) {
  try { return JSON.parse(device.muted_topics ?? '[]').includes(topicFor(story.tags)); } catch { return false; }
}

export async function notify(stories) {
  if (!stories.length) return [];
  const bearer = await token();
  const [jwt, targets] = await Promise.all([credentials(), devices(bearer)]);
  const failures = [];
  for (const environment of Object.keys(hosts)) {
    const group = targets.filter(device => device.environment === environment);
    if (!group.length) continue;
    const client = connect(hosts[environment]);
    client.on('error', () => {});
    let unusable = false;
    for (const story of stories) {
      if (unusable) break;
      const payload = { aps: { alert: { body: story.title }, sound: 'default', 'interruption-level': 'time-sensitive', 'content-available': 1, 'thread-id': story.feed ?? 'wire' }, id: story.id, url: story.url, feed: story.feed ?? 'wire' };
      for (const device of group) {
        if (muted(device, story)) continue;
        const result = await send(client, jwt, device, payload);
        if (result.status === 200) continue;
        if (result.reason === 'BadEnvironmentKeyInToken') { unusable = true; break; }
        if (result.status === 410 || result.reason === 'BadDeviceToken' || result.reason === 'Unregistered') {
          await fetch(new URL(`/v1/devices/${device.token}`, origin), { method: 'DELETE', headers: { Authorization: `Bearer ${bearer}` } }).catch(() => {});
        } else failures.push(`apns ${result.status} ${result.reason ?? ''}`.trim());
      }
    }
    client.close();
  }
  await markWoken().catch(() => {});
  return [...new Set(failures)];
}

// Silent background pushes let the app refresh its feed while suspended, so it opens with new stories,
// images and article text already in place. iOS budgets these per device, so they are coalesced to at
// most one per interval, and skipped when an alert (which also carries content-available) just went out.
const wakeFile = join(directory, 'apns-wake.json');
const wakeInterval = Number(process.env.APNS_WAKE_MINUTES ?? 20) * 60000;

export async function wake() {
  const last = JSON.parse(await readFile(wakeFile, 'utf8').catch(() => '{}')).at ?? 0;
  if (Date.now() - last < wakeInterval) return [];
  // Claim the interval before sending so a misconfigured key reports once per interval, not on every run.
  await markWoken();
  const bearer = await token();
  const [jwt, targets] = await Promise.all([credentials(), devices(bearer)]);
  const failures = [];
  for (const environment of Object.keys(hosts)) {
    const group = targets.filter(device => device.environment === environment);
    if (!group.length) continue;
    const client = connect(hosts[environment]);
    client.on('error', () => {});
    for (const device of group) {
      const result = await send(client, jwt, device, { aps: { 'content-available': 1 } }, 'background');
      if (result.status === 200) continue;
      if (result.reason === 'BadEnvironmentKeyInToken') break;
      if (result.status === 410 || result.reason === 'BadDeviceToken' || result.reason === 'Unregistered') {
        await fetch(new URL(`/v1/devices/${device.token}`, origin), { method: 'DELETE', headers: { Authorization: `Bearer ${bearer}` } }).catch(() => {});
      } else failures.push(`apns wake ${result.status} ${result.reason ?? ''}`.trim());
    }
    client.close();
  }
  return [...new Set(failures)];
}

/** Records that the app was just woken, so an alert push also resets the silent-push interval. */
export async function markWoken() {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(wakeFile, `${JSON.stringify({ at: Date.now() })}\n`, { mode: 0o600 });
}
