import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';
import { canonicalUrl, dedupeCandidates, exactDuplicate, nearIdentical } from '../../scripts/monitor/headline-dedupe.mjs';
import { prefiltered } from '../../scripts/monitor/rules/headlines.mjs';

const { calculatePulse } = await import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: ['src/market-pulse.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const item = (key, title, extra = {}) => ({ key, title, summary: '', publisher: 'Outlet', url: `https://example.com/${key}`, stamp: Date.parse('2026-10-12T10:00:00Z'), ...extra });
const attack = item('reuters', 'Missile attack hits Saudi Aramco oil facilities', { publisher: 'Reuters' });

test('tracking parameters and hosts do not create new URLs; a revised figure under a reused title does', () => {
  assert.equal(canonicalUrl('http://www.example.com/a/?utm_source=x&b=2&a=1#top'), canonicalUrl('https://example.com/a?a=1&b=2'));
  assert.equal(exactDuplicate(item('a', 'GDP rises', { summary: 'Output grew 2.1%' }), item('b', 'GDP rises', { summary: 'Output grew 2.4%' })), false);
  assert.equal(exactDuplicate(item('a', 'GDP rises'), item('b', 'GDP  Rises')), true);
  assert.equal(nearIdentical(attack, item('b', 'Saudi Aramco oil facilities hit by missile attack')), true);
  assert.equal(nearIdentical(item('a', 'Oil jumps 5% after Saudi Aramco attack'), item('b', 'Oil jumps 7% after Saudi Aramco attack')), false);
  const release = summary => item('r', 'U.S. International Trade in Goods and Services, August 2026', { summary });
  assert.equal(nearIdentical(release('Deficit was $59.6 billion'), release('Deficit was $61.2 billion')), false);
});

test('syndicated coverage collapses onto the first story while a material development stays separate', async () => {
  const asked = [];
  const ask = async text => {
    asked.push(text);
    return { duplicate: { choice: /restores/i.test(text) ? 'new' : 'same_0', confidence: 0.9 } };
  };
  const copy = item('ap', 'Drone strike on Aramco plant knocks out Saudi output', { publisher: 'Associated Press' });
  const restored = item('bbc', 'Saudi Aramco restores oil production after attack', { publisher: 'BBC' });
  const reworded = item('cbs', 'Saudi Aramco oil facilities hit by missile attack', { publisher: 'CBS News' });
  const { decisions } = await dedupeCandidates([attack, copy, reworded, restored], [], { ask });
  assert.deepEqual(decisions.map(d => [d.key, d.status, d.representative, d.reason]),
    [['reuters', 'new', 'reuters', 'distinct'], ['ap', 'duplicate', 'reuters', 'semantic-same-event'], ['cbs', 'duplicate', 'reuters', 'near-identical'], ['bbc', 'new', 'bbc', 'distinct']]);
  assert.equal(asked.length, 2);
});

test('classifier outages defer publication instead of letting a possible copy through', async () => {
  const copy = item('ap', 'Drone strike on Aramco plant knocks out Saudi output');
  const failing = await dedupeCandidates([copy], [attack], { ask: async () => { throw new Error('quota'); } });
  assert.equal(failing.decisions[0].status, 'deferred');
  assert.equal(failing.error, 'quota');
  const offline = await dedupeCandidates([copy, item('x', attack.title)], [attack], { historyAvailable: false });
  assert.deepEqual(offline.decisions.map(d => d.status), ['deferred', 'duplicate']);
  const unsure = await dedupeCandidates([copy], [attack], { ask: async () => ({ duplicate: { choice: 'new', confidence: 0.5 } }) });
  assert.equal(unsure.decisions[0].status, 'duplicate');
});

test('quote and calendar pages never reach classification', () => {
  for (const title of ['WFC Oct 2026 79.000 call (WFC261016C00079000) Stock Price, News, Quote & History', 'Earnings calendar for:', '- Yahoo Finance'])
    assert.equal(prefiltered(item('q', title, { url: 'https://news.google.com/rss/articles/abc' })), true, title);
  assert.equal(prefiltered(item('n', 'Stocks fall as oil prices surge', { url: 'https://news.google.com/rss/articles/abc' })), false);
});

test('independent outlets corroborate an unconfirmed report up to, never beyond, a confirmed one', () => {
  const cutoff = '2026-10-12T11:00:00Z';
  const story = (id, source, title = 'Missile attack reportedly hits Saudi oil facilities') => ({ id, title, summary: '', source, url: `https://example.com/${id}`,
    published_at: '2026-10-12T10:00:00Z', received_at: '2026-10-12T10:01:00Z', retracted_at: null, tags: ['headlines'], tickers: [] });
  const single = calculatePulse([story('a', 'Reuters')], cutoff).score;
  const editions = calculatePulse([story('a', 'Yahoo Finance UK'), story('b', 'Yahoo! Finance Canada')], cutoff).score;
  const three = calculatePulse([story('a', 'Reuters'), story('b', 'Associated Press'), story('c', 'BBC')], cutoff);
  const confirmed = calculatePulse([story('a', 'Reuters', 'Missile attack hits Saudi oil facilities')], cutoff).score;
  assert.equal(editions, single);
  assert.ok(three.score < single);
  assert.ok(three.score >= confirmed);
  assert.equal(calculatePulse(Array.from({ length: 12 }, (_, i) => story(`s${i}`, `Outlet ${i}`)), cutoff).score, confirmed);
  assert.equal(three.factors.find(f => f.evidence.length).evidence[0].independent_sources, 3);
});
