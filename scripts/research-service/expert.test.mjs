import assert from 'node:assert/strict';
import test from 'node:test';

import { breadth, composeBody, parsePercent, themeFor, themes } from './expert.mjs';

const now = Date.parse('2026-10-22T20:00:00Z');
const row = (symbol, day, month, ytd, extra = {}) => ({ symbol, name: symbol, price: '100.00', day, month, ytd, quoted_at: '2026-10-22T19:59:00.000Z', stale: false, ...extra });

test('parsePercent reads signed tool percentages and rejects other text', () => {
  assert.equal(parsePercent('−7.5%'), -7.5);
  assert.equal(parsePercent('+137%'), 137);
  assert.equal(parsePercent('n/a'), null);
});

test('breadth counts only current quotes but keeps every name in period medians', () => {
  const stats = breadth([row('A', 2, 10, 20), row('B', -1, -5, 4), row('C', 0, 1, 1), row('D', 9, 3, 50, { stale: true }), row('E', null, null, null)]);
  assert.equal(stats.usable, 3);
  assert.equal(stats.total, 5);
  assert.deepEqual([stats.up, stats.down], [1, 1]);
  assert.equal(stats.median_day, 0);
  assert.equal(stats.median_month, 2);
  assert.deepEqual(stats.best[0], 'A');
  assert.deepEqual(stats.worst[0], 'B');
});

test('composeBody escapes model text, labels AI output and builds the board from code', () => {
  const rows = [row('NVDA', -4.4, -7.3, 13.8), row('AMD', -8.2, -18.6, 137), row('X', null, null, null, { stale: true, quoted_at: null, price: null })];
  const html = composeBody({
    key_points: ['<script>x</script> chips fell'], sections: [{ heading: 'Chips', paragraphs: ['A & B'] }], watch: ['Earnings'],
    sources: [{ title: 'Ok', url: 'https://example.com' }, { title: 'Bad', url: 'javascript:alert(1)' }],
  }, { rows, benchmarks: [row('QQQ', -2, -3, 18)], stats: breadth(rows), theme: themes.ai, generatedAt: now, modelName: 'test-model' });
  assert.match(html, /AI-generated analysis/);
  assert.match(html, /&lt;script&gt;/);
  assert.doesNotMatch(html, /javascript:/);
  assert.match(html, /<b>AMD<\/b> 100\.00 · day −8\.2% · 1M −18\.6% · YTD \+137\.0%/);
  assert.match(html, /<b>X<\/b> n\/a · day n\/a .* · stale/);
  assert.match(html, /1 quotes were stale or unavailable/);
  assert.ok(html.indexOf('<b>AMD</b>') < html.indexOf('<b>NVDA</b>'));
});

test('themeFor rotates on New York weekdays and skips weekends', () => {
  assert.equal(themeFor(Date.parse('2026-10-19T21:30:00Z')), 'ai');
  assert.equal(themeFor(Date.parse('2026-10-22T21:30:00Z')), 'ai');
  assert.equal(themeFor(Date.parse('2026-10-23T21:30:00Z')), 'consumer');
  assert.equal(themeFor(Date.parse('2026-10-24T21:30:00Z')), null);
});
