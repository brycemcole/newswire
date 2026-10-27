import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseDraft, relatedStories, reviewAlerts } from '../../scripts/monitor/alert-review.mjs';

const now = Date.parse('2026-10-27T08:00:00Z');
const story = { id: 's1', title: 'ITS HAPPENING !!!!! Microsoft Offers Exit Packages to 60,000 Employees Amid AI Push', summary: '', source: 'crazymonkey1', url: 'https://x.com/cxetnk/status/1', tags: ['x'], published_at: '2026-10-27T07:36:00Z' };
const recent = [
  story,
  { id: 's2', title: 'Microsoft is offering buyouts to around 60,000 employees', summary: '', source: 'Business Insider', url: 'https://example.com/a', published_at: '2026-10-27T05:00:00Z' },
  { id: 's3', title: 'ConocoPhillips to reduce workforce in Canada', summary: '', source: 'Reuters', url: 'https://example.com/b', published_at: '2026-10-27T07:00:00Z' },
];
const draft = content => async () => ({ choices: [{ message: { content } }] });

test('related stories exclude the story itself and unrelated headlines', () => {
  assert.deepEqual(relatedStories(story, recent).map(other => other.id), ['s2']);
});

test('drafts are parsed from fenced JSON and require both fields', () => {
  assert.deepEqual(parseDraft('```json\n{"title":"Microsoft buyouts","body":"Business Insider reports."}\n```'), { title: 'Microsoft buyouts', body: 'Business Insider reports.' });
  assert.throws(() => parseDraft('{"title":"x"}'));
});

test('an approved draft replaces the source headline in the notification', async () => {
  const seen = [];
  const { approved, held } = await reviewAlerts([story], recent, {
    now,
    write: draft('{"title":"Microsoft offers buyouts","body":"Business Insider reports exit packages for about 60,000 employees."}'),
    review: async (text, question) => { seen.push(text); return { verdict: { choice: 'send', confidence: 0.9 } }; },
  });
  assert.equal(approved[0].alert.title, 'Microsoft offers buyouts');
  assert.equal(held.length, 0);
  assert.match(seen[0], /Business Insider \(180m ago\)/);
  assert.match(seen[0], /Draft notification:\nMicrosoft offers buyouts/);
});

test('held, low-confidence and failed reviews send nothing', async () => {
  const write = draft('{"title":"t","body":"b"}');
  for (const review of [async () => ({ verdict: { choice: 'hold', confidence: 0.95 } }), async () => ({ verdict: { choice: 'send', confidence: 0.4 } })]) {
    const result = await reviewAlerts([story], recent, { now, write, review });
    assert.equal(result.approved.length, 0);
    assert.equal(result.held.length, 1);
  }
  const broken = await reviewAlerts([story], recent, { now, write: draft('not json'), review: async () => { throw new Error('unused'); } });
  assert.equal(broken.approved.length, 0);
  assert.equal(broken.failures.length, 1);
});
