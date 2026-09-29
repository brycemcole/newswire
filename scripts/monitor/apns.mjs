import { createSign } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { connect } from 'node:http2';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { token } from './publish.mjs';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const directory = join(homedir(), '.config', 'newswire');
const hosts = { sandbox: 'https://api.sandbox.push.apple.com', production: 'https://api.push.apple.com' };

async function credentials() {
  const config = JSON.parse(await readFile(join(directory, 'apns.json'), 'utf8').catch(() => '{}'));
  const keyId = process.env.APNS_KEY_ID ?? config.key_id;
  const teamId = process.env.APNS_TEAM_ID ?? config.team_id ?? 'A792L5W262';
  const key = await readFile(process.env.APNS_KEY_FILE ?? join(directory, 'apns-key.p8'), 'utf8').catch(() => '');
  if (!keyId || !key.trim()) throw new Error('APNs is not configured: add ~/.config/newswire/apns-key.p8 and key_id in apns.json');
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = `${encode({ alg: 'ES256', kid: keyId })}.${encode({ iss: teamId, iat: Math.floor(Date.now() / 1000) })}`;
  return `${unsigned}.${createSign('SHA256').update(unsigned).sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

async function devices(bearer) {
  const response = await fetch(new URL('/v1/devices', origin), { headers: { Authorization: `Bearer ${bearer}` }, signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`devices ${response.status}`);
  return (await response.json()).devices;
}

function send(client, jwt, device, payload) {
  return new Promise(resolve => {
    const request = client.request({
      ':method': 'POST',
      ':path': `/3/device/${device.token}`,
      authorization: `bearer ${jwt}`,
      'apns-topic': process.env.APNS_TOPIC ?? 'com.brycecole.newswire',
      'apns-push-type': 'alert',
      'apns-priority': '10',
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
  return [...new Set(failures)];
}
