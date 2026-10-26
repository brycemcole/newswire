import assert from 'node:assert/strict';
import test from 'node:test';
import { acceptedTopic, balanceHeadlines, classificationText, optionsFlowQuestion, optionsFlowReport, parseFeed, significanceTag } from '../../scripts/monitor/rules/headlines.mjs';

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
  assert.deepEqual(balanceHeadlines(stories).map(s => s.title), ['Breaking', 'Publisher']);
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

test('geopolitics needs confident financial relevance, not merely a news event', () => {
  const answers = { topic: { choice: 'geopolitical-security', confidence: 0.95 }, format: { choice: 'news', confidence: 0.95 } };
  assert.equal(acceptedTopic(answers), null);
  assert.equal(acceptedTopic({ ...answers, relevance: { choice: 'incidental', confidence: 0.95 } }), null);
  assert.equal(acceptedTopic({ ...answers, relevance: { choice: 'financial', confidence: 0.5 } }), null);
  const financial = { ...answers, relevance: { choice: 'financial', confidence: 0.95 } };
  assert.equal(acceptedTopic(financial), 'geopolitical-security');
  assert.equal(acceptedTopic(financial, { x: true }), 'geopolitical-security');
  assert.equal(acceptedTopic({ ...financial, format: { choice: 'feature', confidence: 0.95 } }), null);
});

test('every X topic requires financial relevance, including politics and company mentions', () => {
  for (const topic of ['midterms-2026', 'company-outlook', 'us-market-movers', 'geopolitical-security']) {
    const answers = { topic: { choice: topic, confidence: 0.95 }, format: { choice: 'news', confidence: 0.95 } };
    assert.equal(acceptedTopic(answers, { x: true }), null);
    assert.equal(acceptedTopic({ ...answers, relevance: { choice: 'incidental', confidence: 0.95 } }, { x: true }), null);
    assert.equal(acceptedTopic({ ...answers, relevance: { choice: 'financial', confidence: 0.95 } }, { x: true }), topic);
    for (const confidence of [0.5, undefined, NaN]) {
      assert.equal(acceptedTopic({ ...answers, relevance: { choice: 'financial', confidence } }, { x: true }), null);
    }
  }
});

test('rolling hourly X limit spans runs, uses receipt time, and preserves articles', () => {
  const now = Date.parse('2026-10-26T14:00:00Z');
  const article = { title: 'Earnings report', tags: ['headlines'], priority: 'normal', published_at: new Date(now).toISOString() };
  const post = { ...article, title: 'Fed decision', tags: ['x'], priority: 'breaking' };
  const history = minutes => ({ tags: ['x'], published_at: new Date(now - 5 * 3600000).toISOString(), received_at: new Date(now - minutes * 60000).toISOString() });
  assert.deepEqual(balanceHeadlines([post, article], undefined, { now, published: [history(10)] }), [post, article]);
  assert.deepEqual(balanceHeadlines([post, article], undefined, { now, published: [history(10), history(50)] }), [article]);
  assert.deepEqual(balanceHeadlines([post, article], undefined, { now, published: [history(10), history(60)] }), [post, article]);
  assert.deepEqual(balanceHeadlines([post, article], undefined, { now, historyAvailable: false }), [article]);
});

test('legacy mirror entries still count X URLs toward the hourly limit', () => {
  const now = Date.parse('2026-10-26T14:00:00Z');
  const post = { title: 'Fed decision', tags: ['x'], priority: 'breaking', published_at: new Date(now).toISOString() };
  const published = ['https://x.com/financialjuice/status/123', 'https://twitter.com/unusual_whales/status/456'].map(url => ({ url, published_at: new Date(now - 600000).toISOString() }));
  assert.deepEqual(balanceHeadlines([post], undefined, { now, published }), []);
});

test('attributed options-flow analysis is admitted narrowly from publishers and X', () => {
  const answers = {
    topic: { choice: 'options-flow', confidence: 0.95 },
    format: { choice: 'feature', confidence: 0.95 },
    relevance: { choice: 'financial', confidence: 0.95 },
    evidence: { choice: 'attributed', confidence: 0.95 },
  };
  for (const x of [false, true]) {
    assert.equal(acceptedTopic(answers, { x }), 'options-flow');
    assert.equal(acceptedTopic({ ...answers, format: { choice: 'news', confidence: 0.95 } }, { x }), 'options-flow');
    for (const evidence of [undefined, { choice: 'unsupported', confidence: 0.95 }, { choice: 'attributed', confidence: 0.5 }, { choice: 'attributed' }]) {
      assert.equal(acceptedTopic({ ...answers, evidence }, { x }), null);
    }
  }
  assert.equal(acceptedTopic({ ...answers, relevance: undefined }, { x: true }), null);
  assert.equal(acceptedTopic({ ...answers, relevance: { choice: 'incidental', confidence: 0.95 } }, { x: true }), null);
  assert.equal(acceptedTopic({ ...answers, topic: { choice: 'market-analysis', confidence: 0.95 } }, { x: true }), null);
  assert.match(optionsFlowQuestion.evidence.criteria.attributed, /named bank/);
  assert.match(optionsFlowQuestion.evidence.criteria.unsupported, /figures without an identified underlying source/);
});

test('long X reports retain attribution and trade evidence for classification', () => {
  const summary = `${'Market context. '.repeat(30)}From Nomura: CRWV buyer of 21k Apr 80 calls for $7.15 (10/22).`;
  const text = classificationText({ title: 'And here we go, Round 3', summary, x: true });
  assert.ok(text.includes('From Nomura:'));
  assert.ok(text.includes('21k Apr 80 calls for $7.15 (10/22)'));
  assert.ok(classificationText({ title: 'Report', summary: 'x'.repeat(20000), x: true }).length < 12100);
});

test('options-flow presentation separates publication from observations and preserves reported figures', () => {
  const item = {
    title: 'And here we go, Round 3', publisher: '@zerohedge',
    stamp: Date.parse('2026-10-26T20:00:00Z'),
    summary: 'From Nomura: CRWV: $69M premium, delta of 3M shares or $170M.\nBuyer of 21k Apr 80 calls for $7.15 (10/22).\nBuyer of 20k Mar 80 calls for $8.85 (10/14).',
  };
  const report = optionsFlowReport(item);
  assert.match(report.title, /^Reported options flow via @zerohedge:/);
  assert.match(report.summary, /^Source-reported options flow via @zerohedge; not independently verified/);
  assert.ok(report.body.includes(item.summary));
  assert.match(report.body, /Report published at 2026-10-26T20:00:00.000Z; this is not the trade observation time/);
  assert.match(report.body, /newly published report does not make those observations current/);
  assert.match(report.body, /Delta-equivalent exposure is not shares purchased/);
  assert.match(report.body, /spreads, hedges or closing trades/);
  assert.match(report.body, /does not establish investor identity or intent/);
  assert.equal(item.stamp, Date.parse('2026-10-26T20:00:00Z'));
  assert.ok(!report.body.includes('2026-10-22'));
});

test('missing observation dates stay unknown and an empty summary retains the original report', () => {
  const report = optionsFlowReport({ title: 'Exchange reports 500 call contracts', summary: '', publisher: 'Test publisher', stamp: Date.parse('2026-10-26T20:00:00Z') });
  assert.match(report.body, /Missing dates or years are unknown, not inferred/);
  assert.match(report.summary, /Exchange reports 500 call contracts/);
  assert.match(report.body, /Source text \(Test publisher\):\nExchange reports 500 call contracts/);
});

test('only supported confident significance labels reach story tags', () => {
  for (const choice of ['systemic-event', 'material-company-event', 'routine-company-update']) {
    assert.equal(significanceTag({ significance: { choice, confidence: 0.9 } }), choice);
    assert.equal(significanceTag({ significance: { choice, confidence: 0.4 } }), null);
  }
  assert.equal(significanceTag({}), null);
  assert.equal(significanceTag({ significance: { choice: 'other', confidence: 1 } }), null);
  assert.equal(significanceTag({ significance: { choice: 'made-up', confidence: 1 } }), null);
});
