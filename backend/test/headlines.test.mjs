import assert from 'node:assert/strict';
import test from 'node:test';
import { acceptedTopic, balanceHeadlines, parseFeed } from '../../scripts/monitor/rules/headlines.mjs';

test('Yahoo RSS links decode query entities and remove syndication tracking', () => {
  const items = parseFeed(`<rss><channel><item>
    <title><![CDATA[Company raises guidance & announces buyback]]></title>
    <link>https://finance.yahoo.com/news/results.html?symbol=ABC&amp;edition=us&amp;.tsrc=rss</link>
    <pubDate>Tue, 06 Oct 2026 21:00:00 GMT</pubDate>
    <description>Revenue is expected to increase 20% this year.</description>
  </item></channel></rss>`, 'Yahoo Finance');
  assert.equal(items.length, 1);
  assert.equal(items[0].url, 'https://finance.yahoo.com/news/results.html?symbol=ABC&edition=us');
  assert.equal(items[0].publisher, 'Yahoo Finance');
  assert.equal(items[0].stamp, Date.parse('2026-10-06T21:00:00Z'));
});

test('Google discovery preserves the publisher and removes its title suffix', () => {
  const [item] = parseFeed(`<rss><channel><item>
    <title>Bond yields rise - Yahoo Finance</title><source url="https://finance.yahoo.com">Yahoo Finance</source>
    <link>https://news.google.com/rss/articles/example</link><guid>example</guid>
    <pubDate>Tue, 06 Oct 2026 21:00:00 GMT</pubDate>
  </item></channel></rss>`, 'Google News');
  assert.equal(item.publisher, 'Yahoo Finance');
  assert.equal(item.title, 'Bond yields rise');
});

test('publisher headlines lead equal-priority X posts and X cannot fill a batch', () => {
  const event = (title, x, priority = 'normal') => ({ title, priority, tags: x ? ['x'] : ['headlines'], published_at: '2026-10-06T21:00:00Z' });
  const stories = [event('X 1', true), event('Publisher', false), event('X 2', true), event('X 3', true), event('Breaking', true, 'breaking')];
  assert.deepEqual(balanceHeadlines(stories).map(s => s.title), ['Breaking', 'Publisher', 'X 1']);
  assert.deepEqual(balanceHeadlines(stories, 0).map(s => s.title), ['Publisher']);
});

test('useful publisher financial analysis is accepted without admitting X commentary or unrelated features', () => {
  const answers = (topic, format, confidence = 0.9) => ({ topic: { choice: topic, confidence }, format: { choice: format, confidence } });
  assert.equal(acceptedTopic(answers('market-analysis', 'feature')), 'market-analysis');
  assert.equal(acceptedTopic(answers('market-analysis', 'feature'), { x: true }), null);
  assert.equal(acceptedTopic(answers('market-analysis', 'feature', 0.5)), null);
  assert.equal(acceptedTopic(answers('ai-and-antitrust', 'feature')), null);
  assert.equal(acceptedTopic(answers('company-outlook', 'news')), 'company-outlook');
});
