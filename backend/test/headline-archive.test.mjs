import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { archiveHeadlines } from '../../scripts/monitor/headline-archive.mjs';
import { migrateLegacyEvidence, readEvidence } from '../../scripts/monitor/evidence-store.mjs';

test('raw intake survives classifier outages without backdating arrival or changing old evidence', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-archive-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'archive.json'), now = Date.parse('2026-10-13T00:00:00Z');
  const item = { title: 'Original headline', summary: 'Original summary', url: 'https://example.com/story', guid: 'one', publisher: 'Publisher', stamp: now - 2 * 86400000 };
  await archiveHeadlines([item], { now, file });
  const result = await archiveHeadlines([{ ...item, title: 'Later edited headline' }], { now: now + 3600000, file });
  assert.equal(result.records.length, 2);
  assert.equal(result.records[0].first_seen_at, new Date(now).toISOString());
  assert.equal(result.records.find(record => record.title === 'Original headline').stamp, item.stamp);
  const evidence = await readEvidence(`${file}.evidence.jsonl`, { type: 'headline_version' });
  assert.equal(evidence.length, 2);
  assert.notEqual(evidence[0].content_hash, evidence[1].content_hash);
  assert.equal(evidence[1].canonical_url, 'https://example.com/story');
  assert.equal(evidence[1].source, 'Publisher');
  assert.equal(evidence[1].observed_at, new Date(now + 3600000).toISOString());
  assert.equal(evidence[1].first_seen_at, new Date(now).toISOString());
  const noisyRepeat = { ...item, title: 'Later edited headline', observed_at: new Date(now + 2 * 3600000).toISOString(),
    provenance: { via: ['feed-b', 'feed-a'] }, content_hash: 'crawler-generated-per-run-hash' };
  await archiveHeadlines([noisyRepeat], { now: now + 2 * 3600000, file });
  assert.equal((await readEvidence(`${file}.evidence.jsonl`, { type: 'headline_version' })).length, 2);
  assert.equal((await archiveHeadlines([], { now: now + 8 * 86400000, file })).records.length, 0);
  assert.deepEqual(JSON.parse(await readFile(file, 'utf8')), {});
  assert.equal((await readEvidence(`${file}.evidence.jsonl`, { type: 'headline_version' })).length, 2);
});

test('multiple edits for one GUID in a batch get distinct hot IDs and retain one durable first_seen', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-archive-batch-revisions-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'archive.json'), now = Date.parse('2026-10-13T00:00:00Z');
  const item = title => ({ title, summary: 'Shared body', body: 'Article body', url: 'https://example.com/story?utm_source=feed', guid: 'same-guid', publisher: 'Publisher', stamp: now });
  const result = await archiveHeadlines([item('First'), item('Second'), item('Third')], { now, file });
  assert.equal(result.records.length, 3);
  const versions = await readEvidence(`${file}.evidence.jsonl`, { type: 'headline_version' });
  assert.equal(versions.length, 3);
  assert.deepEqual(versions.map(version => version.first_seen_at), Array(3).fill(new Date(now).toISOString()));
  assert.equal(new Set(versions.map(version => version.content_hash)).size, 3);
});

test('concurrent intake appends every article version and preserves the legacy raw archive', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-archive-concurrent-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'archive.json'), now = Date.parse('2026-10-13T00:00:00Z');
  const legacy = { legacy: { title: 'Existing legacy story', publisher: 'Legacy', guid: 'old', stamp: now, first_seen_at: new Date(now - 1000).toISOString() } };
  await (await import('node:fs/promises')).writeFile(file, JSON.stringify(legacy));
  const items = Array.from({ length: 16 }, (_, index) => ({ title: `Story ${index}`, summary: '', url: `https://example.com/${index}?utm_source=test`, guid: `${index}`, publisher: 'Publisher', stamp: now }));
  await Promise.all(items.map(item => archiveHeadlines([item], { now, file })));
  const raw = JSON.parse(await readFile(file, 'utf8'));
  assert.equal(Object.keys(raw).length, 17);
  assert.equal(raw.legacy.title, 'Existing legacy story');
  assert.equal((await readEvidence(`${file}.evidence.jsonl`, { type: 'headline_version' })).length, 17);
});

test('corrupt append-only evidence is reported with its line number', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-archive-corrupt-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const archive = join(dir, 'archive.json'), file = `${archive}.evidence.jsonl`;
  await (await import('node:fs/promises')).writeFile(file, '{"type":"ok"}\nnot-json\n');
  await assert.rejects(migrateLegacyEvidence(archive, file, () => ({})), /line 2/);
  assert.equal(await readFile(file, 'utf8'), '{"type":"ok"}\nnot-json\n');
  await assert.rejects(readFile(`${archive}.migration-v1`), { code: 'ENOENT' });
});

test('legacy raw archive backfill preserves original arrival time before cache retention prunes it', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-archive-migration-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'archive.json'), now = Date.parse('2026-10-13T00:00:00Z');
  const old = { title: 'Old story full body', summary: 'Original body', publisher: 'Publisher', guid: 'old', url: 'https://example.com/old', stamp: now - 10 * 86400000, first_seen_at: new Date(now - 11 * 86400000).toISOString(), via: ['feed-a'] };
  await (await import('node:fs/promises')).writeFile(file, JSON.stringify({ old }));
  await archiveHeadlines([], { now, file });
  assert.deepEqual(JSON.parse(await readFile(file, 'utf8')), {});
  const [saved] = await readEvidence(`${file}.evidence.jsonl`, { type: 'headline_version' });
  assert.equal(saved.first_seen_at, old.first_seen_at);
  assert.equal(saved.published_at, new Date(old.stamp).toISOString());
  assert.equal(saved.content.summary, old.summary);
  assert.deepEqual(saved.provenance.via, ['feed-a']);
});

test('old incoming items persist durably outside the seven-day hot cache', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-archive-old-input-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'archive.json'), now = Date.parse('2026-10-13T00:00:00Z');
  const old = { title: 'Older item', summary: 'Full body', url: 'https://example.com/old', guid: 'old', publisher: 'Publisher', stamp: now - 9 * 86400000 };
  await archiveHeadlines([old], { now, file });
  assert.deepEqual(JSON.parse(await readFile(file, 'utf8')), {});
  const [saved] = await readEvidence(`${file}.evidence.jsonl`, { type: 'headline_version' });
  assert.equal(saved.content.summary, old.summary);
});
