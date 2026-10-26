import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { classificationCandidates } from '../../scripts/monitor/headline-selection.mjs';
import { accountGroups, accountQuery, items, linkedArticle, sourceItems, timelineSources } from '../../scripts/monitor/x.mjs';

const entry = (publisher, stamp = 1, x = false) => ({ item: { publisher, stamp, x } });
const preferred = ['Financial Times', 'Bloomberg', 'Semafor', 'Reuters'];

test('direct financial publishers get classification slots ahead of noisy intake', () => {
  const noisy = Array.from({ length: 100 }, (_, stamp) => entry('General News', stamp));
  const selected = classificationCandidates([...noisy, ...preferred.map(name => entry(name))], preferred);
  assert.equal(selected.length, 16);
  assert.deepEqual(selected.slice(0, 4).map(value => value.item.publisher), preferred);
  assert.equal(selected[4].item.stamp, 99);
});

test('round robin prevents multiple feeds from one publisher consuming the batch', () => {
  const bloomberg = Array.from({ length: 50 }, (_, stamp) => entry('Bloomberg', stamp));
  const selected = classificationCandidates([...bloomberg, entry('Financial Times'), entry('Semafor'), entry('Reuters')], preferred, 4);
  assert.deepEqual(selected.map(value => value.item.publisher), preferred);
  assert.equal(selected[1].item.stamp, 49);
});

test('articles lead X without excluding X when there is room', () => {
  const post = entry('@FT', 100, true);
  const article = entry('Financial Times', 1);
  assert.deepEqual(classificationCandidates([post, article], preferred, 1), [article]);
  assert.deepEqual(classificationCandidates([post, article], preferred), [article, post]);
  assert.deepEqual(classificationCandidates([], preferred), []);
});

test('article backlogs cannot starve direct X or discovery classification', () => {
  const articles = Array.from({ length: 100 }, (_, stamp) => entry('Bloomberg', stamp));
  const direct = Array.from({ length: 20 }, (_, stamp) => entry('@FT', stamp, true));
  const discovered = Array.from({ length: 20 }, (_, stamp) => ({ item: { publisher: '@reporter', stamp, x: true, discovery: 'For You' } }));
  const selected = classificationCandidates([...articles, ...direct, ...discovered], preferred);
  assert.equal(selected.length, 16);
  assert.equal(selected.filter(value => !value.item.x).length, 12);
  assert.equal(selected.filter(value => value.item.x && !value.item.discovery).length, 2);
  assert.equal(selected.filter(value => value.item.discovery).length, 2);
  assert.equal(new Set(selected).size, 16);
});

test('For You volume cannot crowd Explore out of discovery slots', () => {
  const articles = Array.from({ length: 20 }, (_, stamp) => entry('Bloomberg', stamp));
  const direct = Array.from({ length: 20 }, (_, stamp) => entry('@FT', stamp, true));
  const forYou = Array.from({ length: 40 }, (_, stamp) => ({ item: { publisher: `@reporter${stamp}`, stamp, x: true, discovery: 'For You' } }));
  const explore = { item: { publisher: '@reporter', stamp: 1, x: true, discovery: 'Explore' } };
  const selected = classificationCandidates([...articles, ...direct, ...forYou, explore], preferred);
  assert.ok(selected.includes(explore));
  assert.equal(selected.filter(value => value.item.discovery === 'For You').length, 1);
});

test('curated X queries cover direct publishers and official economic sources, not aggregators', () => {
  const handles = accountGroups.flat();
  for (const expected of ['Bloomberg', 'markets', 'FT', 'FTMarkets', 'Semafor', 'ReutersBiz', 'WSJmarkets', 'CNBC', 'federalreserve', 'BLS_gov', 'BEA_News']) assert.ok(handles.includes(expected));
  for (const excluded of ['financialjuice', 'unusual_whales', 'LiveSquawk']) assert.ok(!handles.includes(excluded));
  assert.equal(accountQuery(['FT', 'Semafor']), '(from:FT OR from:Semafor) -filter:retweets -filter:replies');
  for (const handle of ['markets', 'FT', 'FTMarkets', 'Semafor']) assert.ok(accountGroups.some(group => group.length === 1 && group[0] === handle));
});

const tweet = (username, extra = {}) => ({
  id: '12345', author: { username }, createdAt: '2026-10-25T12:00:00Z',
  text: 'A public company raised revenue guidance after quarterly earnings exceeded analyst expectations.', ...extra,
});

test('source filtering rejects unrelated accounts even if search returns them', () => {
  const selected = items(['FT', 'bloomberg', 'Semafor', 'financialjuice', 'unusual_whales', 'random'].map(name => tweet(name)));
  assert.deepEqual(selected.map(item => item.publisher), ['@FT', '@bloomberg', '@Semafor']);
  assert.ok(selected.every(item => item.x && item.guid === 'x:12345'));
});

test('replies, retweets and missing source identity cannot bypass curated source filtering', () => {
  assert.deepEqual(items([
    tweet('FT', { inReplyToStatusId: '123' }),
    tweet('FT', { text: `RT @someone: ${tweet('FT').text}` }),
    tweet('FT', { author: {} }),
    tweet('FT', { createdAt: 'invalid' }),
  ]), []);
});

test('For You and Explore supplement direct publisher queries without using Following', () => {
  const home = timelineSources.find(source => source.name === 'For You');
  const explore = timelineSources.find(source => source.name === 'Explore');
  assert.equal(home.args[0], 'home');
  assert.ok(!home.args.includes('--following'));
  assert.equal(explore.args[0], 'news');
  assert.ok(explore.args.includes('--with-tweets'));
  assert.ok(explore.args.includes('--news-only'));
  assert.equal(home.curated, false);
  assert.equal(explore.curated, false);
});

test('discovery admits new reporting accounts but retains source and timestamps for financial classification', () => {
  const source = timelineSources.find(source => source.name === 'For You');
  const [post] = sourceItems([tweet('reporter')], source);
  assert.equal(post.publisher, '@reporter');
  assert.equal(post.x, true);
  assert.equal(post.stamp, Date.parse('2026-10-25T12:00:00Z'));
  assert.deepEqual(items([tweet('reporter')]), []);
});

test('Explore contributes original related posts, never unsourced trend summaries', () => {
  const source = timelineSources.find(source => source.name === 'Explore');
  const topics = [{ headline: 'AI-generated trending claim', description: 'Not independently sourced', tweets: [tweet('reporter')] }, { headline: 'Popular trend without evidence' }];
  assert.deepEqual(sourceItems(topics, source).map(item => item.publisher), ['@reporter']);
  assert.equal(sourceItems({ items: topics }, source).length, 1);
  assert.deepEqual(sourceItems([{ headline: 'No source posts' }], source), []);
});

test('publisher article links become normal articles rather than consuming the tweet allowance', () => {
  const [post] = items([tweet('FT')]);
  const article = linkedArticle(post, 'https://www.ft.com/content/example');
  assert.equal(article.publisher, 'Financial Times');
  assert.equal(article.x, false);
  assert.equal(article.stamp, post.stamp);
  assert.equal(article.guid, post.guid);
  assert.equal(linkedArticle(post, 'https://ft.com.evil.example/story').x, true);
  assert.equal(linkedArticle(post, '').x, true);
});

test('concise financial headlines are not discarded for being shorter than sixty characters', () => {
  assert.equal(items([tweet('FT', { text: 'Federal Reserve cuts interest rates by 25 basis points' })]).length, 1);
});

test('FT sector feeds, Bloomberg and Semafor retain enough time to survive classifier queues', async () => {
  const config = JSON.parse(await readFile(new URL('../../scripts/monitor/rules/headlines.watchlist.json', import.meta.url), 'utf8'));
  const ft = config.feeds.filter(feed => feed.name === 'Financial Times');
  assert.ok(ft.some(feed => feed.url === 'https://www.ft.com/markets?format=rss'));
  assert.ok(ft.some(feed => feed.url === 'https://www.ft.com/companies?format=rss'));
  assert.ok(ft.some(feed => feed.url === 'https://www.ft.com/global-economy?format=rss'));
  assert.ok(config.feeds.some(feed => feed.name === 'Semafor' && feed.url === 'https://www.semafor.com/rss.xml'));
  assert.ok(config.feeds.filter(feed => ['Financial Times', 'Bloomberg', 'Semafor'].includes(feed.name)).every(feed => feed.window_minutes >= 240));
  assert.deepEqual(config.preferred_publishers.slice(0, 4), preferred);
});
