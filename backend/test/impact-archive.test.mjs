import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { classifyImpacts } from '../../scripts/monitor/impacts.mjs';
import { appendEvidence, readEvidence } from '../../scripts/monitor/evidence-store.mjs';

test('skipped impact classifications persist with classifier version and classified time', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-impact-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const archiveFile = join(dir, 'raw-headlines.json'), verdictFile = join(dir, 'impact-verdicts.json');
  const now = Date.now(), id = 'story-1';
  await writeFile(archiveFile, JSON.stringify({ [id]: { title: 'New product launch', summary: '', publisher: 'The Verge', url: 'https://example.com/story', stamp: now, first_seen_at: new Date(now).toISOString() } }));
  const options = { now, archiveFile, verdictFile, post: false };
  assert.equal((await classifyImpacts(options)).skipped, 1);
  const evidenceFile = `${archiveFile}.evidence.jsonl`;
  const classifierVersion = JSON.parse(await readFile(verdictFile, 'utf8'))[id].classifier_version;
  const events = await readEvidence(evidenceFile, { type: 'impact_classification', classifierVersion, ids: [id] });
  assert.equal(events.length, 1);
  assert.equal(events[0].status, 'skipped');
  assert.ok(Date.parse(events[0].classified_at) >= now);
  assert.ok(Date.parse(events[0].classified_at) <= Date.now());
  assert.match(events[0].classifier_version, /^[a-f0-9]{12}$/);
  assert.equal((await classifyImpacts(options)).skipped, 0);
  assert.equal((await readEvidence(evidenceFile, { type: 'impact_classification', classifierVersion, ids: [id] })).length, 1);
  const cache = JSON.parse(await readFile(verdictFile, 'utf8'));
  assert.equal(cache[id].status, 'skipped');
});

test('same-millisecond classification transitions remain separate in attempt history order', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-impact-history-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const evidenceFile = join(dir, 'raw-headlines.json.evidence.jsonl');
  const classifiedAt = '2026-10-13T00:00:00.000Z', classifier_version = 'same-version', id = 'same-story';
  await appendEvidence(evidenceFile, [
    { type: 'impact_classification', id, status: 'failure', classified_at: classifiedAt, classifier_version, error: 'provider unavailable' },
    { type: 'impact_classification', id, status: 'classified', classified_at: classifiedAt, classifier_version, verdict: { direction: 1 } },
  ]);
  const latest = await readEvidence(evidenceFile, { type: 'impact_classification', classifierVersion: classifier_version, ids: [id] });
  const history = await readEvidence(evidenceFile, { type: 'impact_classification', classifierVersion: classifier_version, ids: [id], history: true });
  assert.equal(latest.length, 1);
  assert.equal(latest[0].status, 'classified');
  assert.deepEqual(history.map(event => event.status), ['failure', 'classified']);
  await appendEvidence(evidenceFile, [
    { type: 'impact_classification', id, status: 'neutral', classified_at: classifiedAt, classifier_version },
  ]);
  const continued = await readEvidence(evidenceFile, { type: 'impact_classification', classifierVersion: classifier_version, ids: [id], history: true });
  assert.deepEqual(continued.map(event => event.status), ['failure', 'classified', 'neutral']);
});

test('classifier outage leaves older unclassified headlines queued for recovery and reports expired items', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'newswire-impact-backlog-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const archiveFile = join(dir, 'raw-headlines.json'), verdictFile = join(dir, 'impact-verdicts.json');
  const now = Date.now();
  const entry = (title, hoursAgo) => ({ title, summary: '', publisher: 'Market Journal', url: `https://example.com/${title.replaceAll(' ', '-')}`, stamp: now - hoursAgo * 3600000, first_seen_at: new Date(now - hoursAgo * 3600000).toISOString() });
  const archive = { oldest: entry('Oldest recoverable story', 5), next: entry('Next recoverable story', 4), expired: entry('Expired story', 49) };
  await writeFile(archiveFile, JSON.stringify(archive));
  let outage = true;
  const prompts = [];
  const classify = async prompt => {
    prompts.push(prompt);
    if (outage) throw new Error('provider unavailable');
    return { market: { choice: 'higher', confidence: 0.9 }, channel: { choice: 'growth', confidence: 0.9 }, size: { choice: 'moderate', confidence: 0.9 } };
  };
  const options = { now, archiveFile, verdictFile, post: false, classify };
  const unavailable = await classifyImpacts(options);
  assert.equal(unavailable.calls, 1);
  assert.equal(unavailable.backlog, 2);
  assert.equal(unavailable.expired, 1);
  assert.match(prompts[0], /Oldest recoverable story/);

  outage = false;
  const recovered = await classifyImpacts(options);
  assert.equal(recovered.calls, 2);
  assert.equal(recovered.backlog, 0);
  assert.equal(recovered.expired, 1);
  assert.match(prompts[1], /Oldest recoverable story/);
  assert.match(prompts[2], /Next recoverable story/);
  const classifierVersion = JSON.parse(await readFile(verdictFile, 'utf8')).oldest.classifier_version;
  const events = await readEvidence(`${archiveFile}.evidence.jsonl`, { type: 'impact_classification', classifierVersion, ids: ['oldest', 'next'], history: true });
  assert.deepEqual(events.filter(event => event.type === 'impact_classification').map(event => [event.id, event.status]), [
    ['oldest', 'failure'], ['oldest', 'classified'], ['next', 'classified'],
  ]);
});
