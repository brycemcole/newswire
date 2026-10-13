import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const bundled = await build({ entryPoints: ['src/research-discovery.ts'], bundle: true, format: 'esm', write: false });
const discovery = await import(`data:text/javascript,${encodeURIComponent(bundled.outputFiles[0].text)}`);
const schema = [
  await readFile(new URL('../migrations/0013_forecast_ledger.sql', import.meta.url), 'utf8'),
  await readFile(new URL('../migrations/0015_research_discovery.sql', import.meta.url), 'utf8'),
];
let mf, db;
before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true,
    script: 'export default { fetch() { return new Response() } }', compatibilityDate: '2026-09-06', d1Databases: ['DB'] }] }));
  db = await mf.getD1Database('DB');
  for (const migration of schema) await db.batch(migration.split(';').filter(s => s.trim()).map(s => db.prepare(s)));
});
after(async () => { await mf?.dispose(); });

const snapshot = { pulse: { components: { news: { method: 'jev', channels: [
  { channel: 'energy', top: [{ id: 'impact-17', title: 'Saudi oil terminal hit after missile attack' }] },
  { channel: 'rates', top: [{ id: 'impact-18', title: 'Federal Reserve officials signal rate cut' }] },
] }, factors: [] } } };

test('discoverQuestions makes confirmation and contradiction queries from v2 impact channels', async () => {
  const result = await discovery.discoverQuestions(db, snapshot, '2026-10-12T12:00:00Z');
  assert.equal(result.generated, 4);
  assert.ok(result.questions.every(question => question.status === 'open'));
  const energy = result.questions.filter(question => question.event_id === 'impact-17');
  assert.equal(energy.length, 2);
  assert.match(energy.find(question => /confirmation/i.test(question.reason)).query, /saudi oil terminal hit missile attack \(official OR statement\)/);
  assert.match(energy.find(question => /contradictions/i.test(question.reason)).query, /saudi oil terminal hit missile attack \(denied OR corrected OR restored\)/);
  assert.doesNotMatch(energy[0].query, /independent (?:confirmation|contradiction):/i);
  assert.equal(energy.some(question => /confirmation/i.test(question.reason)), true);
  assert.equal(energy.some(question => /contradictions/i.test(question.reason)), true);
  const again = await discovery.discoverQuestions(db, snapshot, '2026-10-12T12:05:00Z');
  const count = await db.prepare('SELECT COUNT(*) AS n FROM research_questions').first();
  assert.equal(again.generated, 4);
  assert.equal(count.n, 4);
});

test('recordDiscovery stores bounded crawler health, attempts and question-linked article provenance', async () => {
  const generated = await discovery.discoverQuestions(db, snapshot, '2026-10-12T13:00:00Z');
  const confirm = generated.questions.find(question => /confirmation/i.test(question.reason));
  const contradict = generated.questions.find(question => /contradictions/i.test(question.reason));
  const report = { started_at: '2026-10-12T13:01:00Z', finished_at: '2026-10-14T13:02:00Z', processed: 30000,
    findings: 1, unique_findings: 1, questions_attempted: 2, queued: 0, health: 'degraded', failures: [
      { url: 'https://publisher.example/article?token=private', error: 'HTTP 503 upstream unavailable' },
      'legacy crawler timeout',
    ],
    stories: [
      { id: 'finding-1', url: 'https://publisher.example/article?edition=us', title: 'Saudi port traffic resumes', content_hash: 'body-sha256-1',
        published_at: '2026-10-12T12:30:00Z', observed_at: '2026-10-12T13:01:30Z', provenance: [`question:${confirm.id}`, { type: 'question', question_id: contradict.id }, 'role:confirm'] },
      { id: 'future-finding', url: 'https://publisher.example/future', title: 'Future dated article', published_at: '2026-10-13T00:00:00Z' },
      { id: 'credential-url', url: 'https://user:pass@publisher.example/private', title: 'Credential URL' },
    ],
    research_questions: [
      { id: confirm.id, status: 'open', attempts: 1, last_status: 'searched', last_attempt_at: '2026-10-12T13:01:40Z', search_role: 'confirm' },
      { id: contradict.id, status: 'open', attempts: 1, last_status: 'robots-blocked', last_attempt_at: '2026-10-12T13:01:41Z', search_role: 'contradict' },
    ] };
  const saved = await discovery.recordDiscovery(db, report, '2026-10-12T13:02:05Z');
  assert.equal(saved.health, 'degraded');
  assert.equal(saved.findings_received, 1);
  const result = await discovery.getDiscovery(db);
  assert.equal(result.status.processed, 10000);
  assert.equal(result.status.finished_at, null);
  assert.deepEqual(result.status.parent_question_ids.sort(), [confirm.id, contradict.id].sort());
  assert.equal(result.status.failures.length, 2);
  assert.doesNotMatch(result.status.failures[0], /private/);
  assert.match(result.status.failures[1], /legacy crawler timeout/);
  assert.equal(result.findings.length, 1);
  assert.equal(result.findings[0].body_hash, 'body-sha256-1');
  assert.equal(result.findings[0].original_url, 'https://publisher.example/article?edition=us');
  assert.deepEqual(result.findings[0].question_ids.sort(), [confirm.id, contradict.id].sort());
  assert.equal(Object.hasOwn(result.findings[0], 'body'), false);
  assert.deepEqual(new Set(result.attempts.map(item => item.status)), new Set(['searched', 'robots-blocked']));
  const rows = await db.prepare('SELECT status FROM research_questions WHERE id IN (?, ?)').bind(confirm.id, contradict.id).all();
  assert.ok(rows.results.every(row => row.status === 'open'));
});

test('question TTL dismisses stale work and caps the active queue', async () => {
  await db.prepare("INSERT INTO research_questions (id, query, reason, status, created_at) VALUES ('expired', 'old query', 'old', 'open', '2026-01-01T00:00:00Z')").run();
  for (let i = 0; i < 105; i++) {
    await db.prepare("INSERT INTO research_questions (id, query, reason, status, created_at) VALUES (?, ?, 'seed', 'open', ?)")
      .bind(`seed-${i}`, `seed query ${i}`, `2026-10-12T12:${String(i % 60).padStart(2, '0')}:00Z`).run();
  }
  await discovery.discoverQuestions(db, snapshot, '2026-10-12T14:00:00Z');
  const expired = await db.prepare("SELECT status FROM research_questions WHERE id='expired'").first();
  const active = await db.prepare("SELECT COUNT(*) AS n FROM research_questions WHERE status IN ('open','queued')").first();
  assert.equal(expired.status, 'dismissed');
  assert.equal(active.n, 100);
  const activeGenerated = await db.prepare("SELECT COUNT(*) AS n FROM research_questions WHERE id LIKE 'rd_%' AND status IN ('open','queued')").first();
  assert.equal(activeGenerated.n, 0);
});

