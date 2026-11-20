import assert from 'node:assert/strict';
import test from 'node:test';

import { capForRanking, chooseBalanced, guessCategory, leadSentences, parseFeed, plainPost, ruleRank, ruleScore } from './scrape.mjs';

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
    { kind: 'markets', source: 'Yahoo Finance', title: 'Iran offers UN deal to reopen Hormuz after cease-fire collapsed' },
    { kind: 'news', source: 'Semafor', title: 'Iran offers a seven-day plan to reopen the Strait of Hormuz' },
    { kind: 'tech', source: 'Lobsters', title: 'A new local database tool ships today' },
  ];
  const chosen = chooseBalanced(items, 3);
  assert.deepEqual(chosen.map(item => item.source), ['Yahoo Finance', 'Lobsters']);
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

const taste = {
  signals: [
    { type: 'like', category: 'Security', title: 'Cloudflare outage takes down dashboard and API' },
    { type: 'like', category: 'AI', title: 'Anthropic releases new Claude model with stronger coding' },
    { type: 'save', category: 'Markets', title: 'Nvidia earnings beat as datacenter revenue jumps' },
    { type: 'dislike', category: 'Tech', title: 'Celebrity smartphone review roundup' },
  ],
  recent: ['Rust compiler adds faster incremental builds for large workspaces'],
};

test('rule ranking favors liked topics and drops disliked items and feed repeats', () => {
  const liked = ruleScore({ title: 'Cloudflare dashboard outage hits EU customers', abstract: 'The API and dashboard are degraded.', boost: 0.5 }, taste);
  const unrelated = ruleScore({ title: 'Hurried Announcement: Alessandro Masullo GRH', abstract: '', boost: 1.2 }, taste);
  const disliked = ruleScore({ title: 'Celebrity smartphone roundup for the holidays', abstract: '', boost: 0 }, taste);
  const repeat = ruleScore({ title: 'Rust compiler ships faster incremental builds for workspaces', abstract: '', boost: 1.5 }, taste);
  assert.ok(liked >= 8, `liked scored ${liked}`);
  assert.ok(unrelated < 8, `unrelated scored ${unrelated}`);
  assert.ok(disliked <= 3, `disliked scored ${disliked}`);
  assert.equal(repeat, 1);
});

test('rule-ranked items get a guessed category and are marked', () => {
  const [security, paper, markets] = ruleRank([
    { title: 'Critical exploit found in popular VPN', kind: 'link' },
    { title: 'Scaling laws for sparse models', kind: 'paper' },
    { title: 'Nvidia shares fall after earnings', kind: 'news' },
  ], taste);
  assert.deepEqual([security.category, paper.category, markets.category], ['Security', 'AI', 'Markets']);
  assert.ok(security.ruled && paper.ruled && markets.ruled);
  assert.equal(guessCategory({ title: 'New Rust release', kind: 'link' }), 'Tech');
});

test('plain posts use the source text, never push, and say they were not summarized', () => {
  const post = plainPost({ key: 'hn:1', kind: 'link', title: 'Cloudflare dashboard outage hits EU customers', abstract: '', url: 'https://example.com/a', source: 'example.com', note: '420 points on Hacker News', category: 'Security', score: 9.4, ruled: true },
    { text: 'Cloudflare reported degraded dashboard and API access in Europe. Engineers are investigating. ' + 'More detail follows. '.repeat(40), from: 'page' });
  assert.equal(post.title, 'Cloudflare dashboard outage hits EU customers');
  assert.match(post.summary, /^Cloudflare reported degraded dashboard and API access in Europe\. Engineers are investigating\./);
  assert.ok(post.summary.length <= 450);
  assert.equal(post.priority, 7);
  assert.match(post.body, /Not summarized/);
  assert.match(post.body, /keyword rules/);
  assert.equal(plainPost({ title: 'No text', abstract: '', score: 9 }, null), null);
});

test('leadSentences keeps whole sentences within the limit', () => {
  assert.equal(leadSentences('One two three. Four five six. Seven.', 20), 'One two three.');
  assert.equal(leadSentences('No terminal punctuation here', 10), 'No termina');
});
