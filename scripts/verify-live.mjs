import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

const base = process.env.NEWSWIRE_URL;
if (!base) throw new Error('NEWSWIRE_URL is required.');
function credential(account) {
  const result = spawnSync('security', ['find-generic-password', '-s', 'com.brycecole.newswire', '-a', account, '-w'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`Missing ${account} Keychain credential.`);
  return result.stdout.trim();
}
const writer = credential('writer');
async function call(path, token, body, method) {
  const verb = method ?? (body ? 'POST' : 'GET');
  const response = await fetch(new URL(path, base), { method: verb, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' }, ...(verb === 'POST' ? { body: JSON.stringify(body) } : {}) });
  return { status: response.status, body: await response.json(), headers: response.headers };
}
assert.equal((await call('/health')).body.ok, true);
assert.equal((await call('/v1/stories')).status, 401);
assert.equal((await call('/v1/stories', writer, {})).status, 400);
const entries = [
  { key: 'pagination', title: 'Read the wire newest first; scroll down for earlier reports', summary: 'Newswire orders reports by their original publication timestamp. Cursor pagination loads earlier reports without shifting pages when new stories arrive.', body: 'Use GET /v1/stories with a reader credential. The response contains stories and next_cursor. Pass next_cursor back as cursor to continue into older reports. Urgency is highlighted but never moves an older story above a newer one.' },
  { key: 'ingestion', title: 'Your agents can submit stories with authenticated GET or JSON POST', summary: 'The v1 ingestion contract accepts attributed headlines, original source links, publication timestamps, optional report text, tickers, and tags.', body: 'Use GET /v1/ingest for short URL-encoded reports or POST /v1/stories for JSON. Send the writer credential in the Authorization header. Reuse external_id on retries; duplicate source URLs are also deduplicated.' },
  { key: 'connection', title: 'Newswire is online — your private agent news desk is ready', summary: 'The Cloudflare backend stores reports in D1 and serves this terminal and the companion iOS reader. These welcome reports describe the system; they are not market news.', body: 'Connect the iOS app using this HTTPS origin and the separate reader token. Reader credentials cannot upload stories. The app checks for incoming stories while active and preserves your position with a new-story banner.' }
];
const created = [];
for (const [index, entry] of entries.entries()) {
  const story = { external_id: `newswire-system:welcome-${entry.key}-v1`, title: entry.title, summary: entry.summary, body: entry.body, source: 'Newswire / System', url: `${base}/guide.html?topic=${entry.key}`, published_at: new Date(Date.now() - (entries.length - index) * 60000).toISOString(), category: 'general', agent: 'newswire-system', tags: ['system', 'welcome'] };
  let result;
  if (index === 1) {
    const params = new URLSearchParams(Object.entries(story).map(([key, value]) => [key, Array.isArray(value) ? value.join(',') : value]));
    result = await call(`/v1/ingest?${params}`, writer);
  } else result = await call('/v1/stories', writer, story);
  assert.ok([200, 201].includes(result.status), JSON.stringify(result.body));
  assert.match(result.headers.get('cache-control'), /no-store/);
  created.push(result.body.story);
  const duplicates = await Promise.all(Array.from({ length: 3 }, () => call('/v1/stories', writer, story)));
  for (const duplicate of duplicates) { assert.equal(duplicate.status, 200); assert.equal(duplicate.body.duplicate, true); assert.equal(duplicate.body.story.id, result.body.story.id); }
}
let cursor = null;
const seen = [];
do {
  const page = await call(`/v1/stories?limit=1${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`, writer);
  assert.equal(page.status, 200);
  seen.push(...page.body.stories);
  cursor = page.body.next_cursor;
} while (cursor && seen.length < 20);
assert.equal(new Set(seen.map((story) => story.id)).size, seen.length);
for (let index = 1; index < seen.length; index++) assert.ok(seen[index - 1].published_at >= seen[index].published_at);
for (const story of created) assert.ok(seen.some((item) => item.id === story.id));
assert.equal((await call('/v1/stories?tag=welcome', writer)).body.stories.length, entries.length);
const probe = { external_id: 'newswire-system:retract-probe-v1', title: 'Retraction probe', summary: 'A temporary story used to verify the retraction tombstone; safe to ignore.', source: 'Newswire / System', url: `${base}/guide.html?topic=retract-probe`, published_at: new Date().toISOString(), category: 'general', agent: 'newswire-system', tags: ['system', 'retract-probe'] };
const probePost = await call('/v1/stories', writer, probe);
assert.ok([200, 201].includes(probePost.status), JSON.stringify(probePost.body));
const probeId = probePost.body.story.id;
const tombstone = await call(`/v1/stories/${probeId}`, writer, null, 'DELETE');
assert.equal(tombstone.status, 200);
assert.ok(tombstone.body.story.retracted_at, JSON.stringify(tombstone.body));
assert.equal((await call('/v1/stories?tag=retract-probe', writer)).body.stories.length, 0);
assert.deepEqual((await call('/v1/stories?tag=retract-probe&retracted=only', writer)).body.stories.map((story) => story.id), [probeId]);
console.log(JSON.stringify({ ok: true, checks: ['health', 'private reads', 'invalid payload', 'POST ingestion', 'GET ingestion', 'concurrent retry deduplication', 'no-store', 'cursor pagination', 'newest-first order', 'tag filter', 'retraction tombstone'], systemStoryCount: created.length, origin: base }, null, 2));
