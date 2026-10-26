import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
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

const mirrorFile = join(homedir(), '.config', 'newswire', 'story-mirror.json');
const FULL_SYNC_MS = 3600000;
const OVERLAP_MS = 2 * 3600000;

async function fetchStories(since, maxPages) {
  const stories = [];
  let cursor;
  for (let page = 0; page < maxPages; page += 1) {
    const url = new URL('/v1/stories', origin);
    url.searchParams.set('limit', '100');
    url.searchParams.set('since', new Date(since).toISOString());
    if (cursor) url.searchParams.set('cursor', cursor);
    const response = await fetch(url, { headers: { Authorization: `Bearer ${await token()}` }, signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`recent stories ${response.status}`);
    const payload = await response.json();
    stories.push(...(payload.stories ?? []).map(story => ({ id: story.id, title: story.title, summary: story.summary ?? '', source: story.source, url: story.url, published_at: story.published_at, received_at: story.received_at, tags: story.tags })));
    cursor = payload.next_cursor;
    if (!cursor) return stories;
  }
  throw new Error(`recent stories exceeded ${maxPages * 100}; dedupe history incomplete`);
}

// The wire is mirrored on this host so the minute-by-minute dedupe pass reads local data. Each run asks D1 only for the last
// two hours of stories; a full resync every hour picks up retractions and late backfills.
export async function recent(hours, maxPages = 20) {
  const now = Date.now(), wanted = now - hours * 3600000;
  const mirror = JSON.parse(await readFile(mirrorFile, 'utf8').catch(() => 'null')) ?? {};
  const stories = new Map((mirror.stories ?? []).map(story => [story.id, story]));
  const incremental = Number.isFinite(mirror.fullAt) && Number.isFinite(mirror.coveredFrom) && mirror.coveredFrom <= wanted && now - mirror.fullAt < FULL_SYNC_MS && now >= mirror.fullAt;
  let state;
  if (incremental) {
    for (const story of await fetchStories(Math.max(wanted, now - OVERLAP_MS), maxPages)) stories.set(story.id, story);
    state = { ...mirror, stories: [...stories.values()] };
  } else {
    const full = await fetchStories(wanted, maxPages);
    state = { fullAt: now, coveredFrom: wanted, stories: full };
  }
  const keep = state.stories.filter(story => Date.parse(story.published_at) >= wanted);
  await mkdir(join(homedir(), '.config', 'newswire'), { recursive: true, mode: 0o700 });
  await writeFile(`${mirrorFile}.tmp`, JSON.stringify({ ...state, stories: keep }), { mode: 0o600 });
  await rename(`${mirrorFile}.tmp`, mirrorFile);
  return keep.sort((a, b) => (a.published_at < b.published_at ? 1 : -1));
}
