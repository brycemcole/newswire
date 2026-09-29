import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

let mf;
const schema = [
  "CREATE TABLE posts (id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))), content TEXT NOT NULL, source_url TEXT, source_type TEXT NOT NULL CHECK(source_type IN ('news', 'paper', 'tech', 'custom')), category TEXT, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')), priority INTEGER NOT NULL DEFAULT 5, viewed_at TEXT DEFAULT NULL)",
  "CREATE TABLE interactions (id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))), post_id TEXT NOT NULL, type TEXT NOT NULL CHECK(type IN ('like', 'dislike', 'save')), created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))",
];
const request = (path, token = 'reader', init = {}) => mf.dispatchFetch(`https://newswire.test${path}`, { ...init, headers: { Authorization: `Bearer ${token}`, ...init.headers } });
const send = (path, data, token = 'writer') => request(path, token, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });

before(async () => {
  const script = (await build({ entryPoints: ['src/index.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true, script, compatibilityDate: '2026-09-06', d1Databases: ['DB', 'BRAIN'], bindings: { READER_TOKEN: 'reader', WRITER_TOKEN: 'writer' }, serviceBindings: { ASSETS: () => new Response('shell') } }] }));
  const db = await mf.getD1Database('BRAIN');
  const migration = await readFile(new URL('../brain/0001_reader_fields.sql', import.meta.url), 'utf8');
  await db.batch([...schema, ...migration.split(';').filter(s => s.trim())].map(s => db.prepare(s)));
  await db.batch([
    db.prepare("INSERT INTO posts (id, content, source_url, source_type, category, created_at, priority) VALUES ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'Anthropic acquired a biotech startup for $400M. It builds research planning tools.', 'https://www.theinformation.com/a', 'news', 'AI', '2026-04-01T10:00:00Z', 9)"),
    db.prepare("INSERT INTO posts (id, content, source_url, source_type, category, created_at, priority) VALUES ('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'Fed holds rates steady as expected', 'https://federalreserve.gov/x', 'news', 'Macro', '2026-04-02T10:00:00Z', 5)"),
    db.prepare("INSERT INTO posts (id, content, source_url, source_type, category, created_at, priority) VALUES ('cccccccccccccccccccccccccccccccc', 'No link post', NULL, 'custom', 'General', '2026-04-03T10:00:00Z', 5)"),
  ]);
});
after(async () => { await mf?.dispose(); });

test('brain posts read as newswire stories with filters and keyset pages', async () => {
  const { stories, next_cursor } = await (await request('/v1/brain/stories')).json();
  assert.equal(stories.length, 2);
  assert.equal(next_cursor, null);
  const [fed, deal] = stories;
  assert.equal(fed.category, 'economy');
  assert.equal(deal.category, 'technology');
  assert.equal(deal.priority, 'urgent');
  assert.equal(deal.title, 'Anthropic acquired a biotech startup for $400M');
  assert.equal(deal.source, 'theinformation.com');
  assert.equal(deal.agent, 'brain');
  assert.equal(deal.published_at, '2026-04-01T10:00:00.000Z');
  for (const [filter, count] of [['category=economy', 1], ['priority=urgent', 1], ['tag=ai', 1], ['source=theinformation.com', 1], ['q=biotech', 1], ['since=2026-04-02T00:00:00Z', 1]]) {
    assert.equal((await (await request(`/v1/brain/stories?${filter}`)).json()).stories.length, count, filter);
  }
  const first = await (await request('/v1/brain/stories?limit=1')).json();
  const second = await (await request(`/v1/brain/stories?limit=1&cursor=${first.next_cursor}`)).json();
  assert.deepEqual([...first.stories, ...second.stories].map(s => s.id), stories.map(s => s.id));
  assert.equal((await request('/v1/brain/stories?cursor=bad')).status, 400);
  assert.equal((await request('/v1/brain/stories/cccccccccccccccccccccccccccccccc')).status, 404);
});

test('writer-only ingest dedupes by url and reader interactions round-trip', async () => {
  const post = { content: 'Clearer title — what the paper found.', title: 'Clearer title', summary: 'What it found.', body: '<p>Details</p>', source: 'arXiv', source_url: 'https://arxiv.org/abs/2609.00001', source_type: 'paper', category: 'Papers', priority: 7, created_at: '2026-04-04T10:00:00Z' };
  assert.equal((await send('/v1/brain/posts', { posts: [post] }, 'reader')).status, 403);
  assert.equal((await send('/v1/brain/posts', { posts: [{ ...post, extra: 1 }] })).status, 400);
  const created = await send('/v1/brain/posts', { posts: [post, post] });
  assert.equal(created.status, 201);
  assert.deepEqual(await created.json(), { inserted: 1, duplicates: 1 });
  assert.deepEqual((await (await send('/v1/brain/known', { urls: [post.source_url, 'https://x.test'] })).json()).known, [post.source_url]);
  const [paper] = (await (await request('/v1/brain/stories?limit=1')).json()).stories;
  assert.equal(paper.title, 'Clearer title');
  assert.equal(paper.body, '<p>Details</p>');
  assert.equal(paper.category, 'science');
  const liked = await (await send(`/v1/brain/stories/${paper.id}/interaction`, { type: 'like' }, 'reader')).json();
  assert.equal(liked.story.interaction, 'like');
  assert.equal((await (await send(`/v1/brain/stories/${paper.id}/interaction`, { type: 'none' }, 'reader')).json()).story.interaction, null);
  assert.equal((await send(`/v1/brain/stories/${paper.id}/interaction`, { type: 'love' }, 'reader')).status, 400);
  assert.equal((await send(`/v1/brain/stories/${paper.id}/view`, {}, 'reader')).status, 200);
  await send(`/v1/brain/stories/${paper.id}/interaction`, { type: 'save' }, 'reader');
  const taste = await (await request('/v1/brain/taste', 'writer')).json();
  assert.equal(taste.signals[0].title, 'Clearer title');
  assert.equal((await request('/v1/brain/taste')).status, 403);
  assert.equal((await send('/v1/brain/ai', { messages: [{ role: 'user', content: 'hi' }] })).status, 503);
});
