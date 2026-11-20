import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { companyName, fallbackVerdict, looksLikeFeature, selectFallback, symbolMentions, watchedSymbols } from '../../scripts/monitor/headline-fallback.mjs';

const now = Date.parse('2026-11-20T23:00:00Z');
const story = (title, extra = {}) => ({ title, summary: '', publisher: 'Reuters', url: `https://example.com/${encodeURIComponent(title)}`, guid: title, stamp: now - 600000, ...extra });
const watched = [{ symbol: 'NET', name: 'Cloudflare' }, { symbol: 'AAPL', name: 'Apple' }, { symbol: 'ON', name: 'ON Semiconductor' }];
const trusted = ['Reuters', 'Bloomberg', 'CNBC'];

test('company names drop legal suffixes and short leftovers', () => {
  assert.equal(companyName('Cloudflare, Inc.'), 'Cloudflare');
  assert.equal(companyName('Apple Inc.'), 'Apple');
  assert.equal(companyName('JPMorgan Chase & Co.'), 'JPMorgan Chase');
  assert.equal(companyName('X Corp'), '');
});

test('held and watched symbols match by ticker, cashtag, exchange tag or company name', () => {
  assert.deepEqual(symbolMentions(story('Cloudflare reports a major service incident'), watched), ['NET']);
  assert.deepEqual(symbolMentions(story('NET slides after outage'), watched), ['NET']);
  assert.deepEqual(symbolMentions(story('Chipmaker beats estimates (NASDAQ: ON)'), watched), ['ON']);
  assert.deepEqual(symbolMentions(story('Apple’s iPhone sales rise'), watched), ['AAPL']);
  // Ambiguous tickers and lowercase common words never match on their own.
  assert.deepEqual(symbolMentions(story('Oil prices rise ON supply fears'), watched), []);
  assert.deepEqual(symbolMentions(story('Farmers expect a big apple harvest'), watched), []);
  assert.deepEqual(symbolMentions(story('The internet is slow today'), watched), []);
});

test('a story naming a held symbol is accepted from any publisher', () => {
  const verdict = fallbackVerdict(story('Cloudflare dashboard outage hits EU customers', { publisher: 'The Verge' }), { watched, trusted, now });
  assert.deepEqual(verdict, { reason: 'symbol', topics: [], tickers: ['NET'] });
});

test('keyword rules apply only to trusted publishers and need an event word', () => {
  assert.deepEqual(fallbackVerdict(story('Fed holds rates steady, signals patience'), { trusted, now })?.topics, ['us-market-movers']);
  assert.deepEqual(fallbackVerdict(story('Acme agrees to buy Widget Co for $4 billion'), { trusted, now })?.topics, ['dealmaking']);
  assert.equal(fallbackVerdict(story('Fed holds rates steady', { publisher: 'Hacker News' }), { trusted, now }), null);
  assert.equal(fallbackVerdict(story('A profile of the Fed chair'), { trusted, now }), null);
  assert.equal(fallbackVerdict(story('Hurried Announcement: Alessandro Masullo GRH', { publisher: 'Hacker News' }), { watched, trusted, now }), null);
});

test('features, X posts and old stories are left for the classifier', () => {
  assert.equal(looksLikeFeature(story('Why stocks fell today')), true);
  assert.equal(looksLikeFeature(story('Opinion: The Fed should cut rates')), true);
  assert.equal(looksLikeFeature(story('3 stocks to buy before earnings')), true);
  assert.equal(fallbackVerdict(story('Is Apple stock a buy?'), { watched, trusted, now }), null);
  assert.equal(fallbackVerdict(story('Apple shares fall', { x: true }), { watched, trusted, now }), null);
  assert.equal(fallbackVerdict(story('Apple shares fall', { stamp: now - 4 * 3600000 }), { watched, trusted, now }), null);
});

test('curated topic feeds keep their topic', () => {
  const verdict = fallbackVerdict(story('Introducing a new model', { publisher: 'OpenAI News' }), { matched: [{ id: 'ai-labs' }], trusted, now });
  assert.deepEqual(verdict, { reason: 'curated-source', topics: ['ai-labs'], tickers: [] });
});

test('selection prefers symbol stories, caps volume and defers possible repeats', () => {
  const entry = (item, reason) => ({ item, fallback: { reason } });
  const entries = [
    entry(story('Stocks slide as Treasury yields jump', { stamp: now - 60000 }), 'keyword'),
    entry(story('Cloudflare outage hits EU dashboard users', { stamp: now - 900000 }), 'symbol'),
    entry(story('Cloudflare EU dashboard outage spreads', { stamp: now - 300000 }), 'symbol'),
    entry(story('Fed holds rates steady'), 'keyword'),
  ];
  const published = [{ title: 'Federal Reserve holds rates steady again', summary: '' }];
  const { chosen, deferred } = selectFallback(entries, published, 2);
  assert.deepEqual(chosen.map(c => c.item.title), ['Cloudflare EU dashboard outage spreads', 'Stocks slide as Treasury yields jump']);
  assert.deepEqual(deferred.map(c => c.item.title), ['Cloudflare outage hits EU dashboard users']);
});

test('watched symbols combine positions and price watches and cache names', async () => {
  const file = join(await mkdtemp(join(tmpdir(), 'fallback-')), 'names.json');
  const devices = [{ stock_symbols: '["NET","AAPL"]', price_watches: '[{"symbol":"NVDA"},{"symbol":"bad symbol"}]' }, { stock_symbols: '["NET"]' }];
  const lookups = [];
  const lookup = async symbol => { lookups.push(symbol); if (symbol === 'NVDA') throw new Error('offline'); return { NET: 'Cloudflare, Inc.', AAPL: 'Apple Inc.' }[symbol]; };
  const first = await watchedSymbols({ load: async () => devices, lookup, file, now });
  assert.deepEqual(first, [{ symbol: 'NET', name: 'Cloudflare' }, { symbol: 'AAPL', name: 'Apple' }, { symbol: 'NVDA', name: '' }]);
  assert.ok(JSON.parse(await readFile(file, 'utf8')).NET);
  lookups.length = 0;
  await watchedSymbols({ load: async () => devices, lookup, file, now: now + 3600000 });
  // Only the failed lookup is retried; fresh names come from the cache.
  assert.deepEqual(lookups, ['NVDA']);
});
