import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';

let cached;
export async function token() {
  if (cached) return cached;
  if (process.env.NEWSWIRE_WRITER_TOKEN) return (cached = process.env.NEWSWIRE_WRITER_TOKEN.trim());
  const value = (await readFile(join(homedir(), '.config', 'newswire', 'writer-token'), 'utf8')).trim();
  if (!value) throw new Error('Writer token file is empty');
  return (cached = value);
}

export async function publish(story) {
  const url = new URL('/v1/stories', origin);
  if (url.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(url.hostname)) throw new Error('HTTPS required');
  const bearer = await token();
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt) await new Promise(resolve => setTimeout(resolve, 1000 * 2 ** attempt));
    let response;
    try {
      response = await fetch(url, { method: 'POST', headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body: JSON.stringify(story), signal: AbortSignal.timeout(20000) });
    } catch (error) {
      lastError = error;
      continue;
    }
    const payload = await response.json().catch(() => ({}));
    if (response.ok) return { duplicate: Boolean(payload.duplicate), id: payload.story?.id };
    if (response.status < 500 && response.status !== 429) throw new Error(`${response.status} ${payload.error?.message ?? 'ingest failed'}`);
    lastError = new Error(`${response.status} ${payload.error?.message ?? 'ingest failed'}`);
  }
  throw lastError ?? new Error('Ingest failed');
}

export async function recent(hours) {
  const url = new URL('/v1/stories', origin);
  url.searchParams.set('limit', '100');
  url.searchParams.set('since', new Date(Date.now() - hours * 3600000).toISOString());
  const response = await fetch(url, { headers: { Authorization: `Bearer ${await token()}` }, signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`recent stories ${response.status}`);
  return ((await response.json()).stories ?? []).map(story => ({ title: story.title, source: story.source }));
}
