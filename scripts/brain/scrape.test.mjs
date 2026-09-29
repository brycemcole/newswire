import assert from 'node:assert/strict';
import test from 'node:test';

import { capForRanking, chooseBalanced, parseFeed } from './scrape.mjs';

test('parseFeed reads RSS and rejects stale entries', () => {
  const fresh = new Date().toUTCString();
  const xml = `<rss><channel>
    <item><title><![CDATA[Fresh & useful]]></title><link>https://example.com/fresh</link><description><![CDATA[Specific details here.]]></description><pubDate>${fresh}</pubDate></item>
    <item><title>Old item</title><link>https://example.com/old</link><pubDate>Tue, 01 Jan 2019 00:00:00 GMT</pubDate></item>
  </channel></rss>`;
  const items = parseFeed(xml, { key: 'test', source: 'Example' });
  assert.equal(items.length, 1);
  assert.equal(items[0].title, 'Fresh & useful');
  assert.equal(items[0].abstract, 'Specific details here.');
});

test('chooseBalanced enforces paper and source quotas', () => {
  const items = [
    { kind: 'paper', source: 'arXiv', title: 'paper 1' },
    { kind: 'paper', source: 'arXiv', title: 'paper 2' },
    { kind: 'news', source: 'Semafor', title: 'news 1' },
    { kind: 'news', source: 'Semafor', title: 'news 2' },
    { kind: 'news', source: 'Semafor', title: 'news 3' },
    { kind: 'tech', source: 'Lobsters', title: 'tech 1' },
  ];
  const chosen = chooseBalanced(items, 5, { maxPapers: 1, maxPerSource: 2 });
  assert.deepEqual(chosen.map(item => item.title), ['paper 1', 'news 1', 'news 2', 'tech 1']);
});

test('chooseBalanced drops the same story from another source', () => {
  const items = [
    { kind: 'markets', source: 'Polymarket', title: 'Iran offers UN deal to reopen Hormuz after cease-fire collapsed' },
    { kind: 'news', source: 'Semafor', title: 'Iran offers a seven-day plan to reopen the Strait of Hormuz' },
    { kind: 'tech', source: 'Lobsters', title: 'A new local database tool ships today' },
  ];
  const chosen = chooseBalanced(items, 3);
  assert.deepEqual(chosen.map(item => item.source), ['Polymarket', 'Lobsters']);
});

test('capForRanking bounds each source and the total paper pool', () => {
  const items = [
    ...Array.from({ length: 5 }, (_, index) => ({ kind: 'paper', source: 'arXiv', title: `paper ${index}` })),
    ...Array.from({ length: 4 }, (_, index) => ({ kind: 'news', source: 'Semafor', title: `news ${index}` })),
    { kind: 'tech', source: 'Lobsters', title: 'tool' },
  ];
  const capped = capForRanking(items, 2, 3);
  assert.equal(capped.filter(item => item.kind === 'paper').length, 3);
  assert.equal(capped.filter(item => item.source === 'Semafor').length, 2);
  assert.equal(capped.filter(item => item.source === 'Lobsters').length, 1);
});
