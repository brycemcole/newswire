import { test } from 'node:test';
import assert from 'node:assert/strict';

const { parseJSON, runAgent } = await import('../../scripts/research-service/llm.mjs');
const { parseBingNews, parseDuckDuckGo, searchArchive } = await import('../../scripts/research-service/tools.mjs');
const { answerQueue } = await import('../../scripts/research-service/agent.mjs');

test('runAgent executes tool calls, returns tool output to the model and parses the final JSON', async () => {
  process.env.DEEPSEEK_API_KEY = 'test-only';
  const requests = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    requests.push({ url, body, headers: init.headers });
    const message = requests.length === 1
      ? { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'quote', arguments: '{"symbol":"SPY"}' } }, { id: 'call_2', type: 'function', function: { name: 'missing', arguments: '{}' } }] }
      : { role: 'assistant', content: '```json\n{"verdict":"confirmed"}\n```' };
    return Response.json({ choices: [{ message, finish_reason: requests.length === 1 ? 'tool_calls' : 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 5 } });
  };
  try {
    const tools = [{ name: 'quote', description: 'q', parameters: { type: 'object', properties: {} }, run: async args => `SPY 500 for ${args.symbol}` }];
    const { result, trace } = await runAgent({ system: 's', prompt: 'p', tools });
    assert.deepEqual(result, { verdict: 'confirmed' });
    assert.equal(trace.length, 2);
    assert.equal(requests[0].url, 'https://api.deepseek.com/chat/completions');
    assert.equal(requests[0].headers.Authorization, 'Bearer test-only');
    assert.deepEqual(requests[0].body.thinking, { type: 'disabled' });
    const toolMessages = requests[1].body.messages.filter(m => m.role === 'tool');
    assert.deepEqual(toolMessages.map(m => m.content), ['SPY 500 for SPY', 'Error: Unknown tool missing']);
    assert.equal(requests[1].body.messages.some(m => m.content === null), false);
  } finally { globalThis.fetch = original; }
});

test('parseJSON tolerates fences and surrounding prose', () => {
  assert.deepEqual(parseJSON('Here you go:\n{"a":1}\nThanks'), { a: 1 });
  assert.throws(() => parseJSON('no json'), /no JSON/);
});

test('open-web parsers unwrap redirect links and keep publishers', () => {
  const bing = `<rss><channel><item><title>Fed&apos;s Waller: cuts &amp; patience</title><link>http://www.bing.com/news/apiclick.aspx?ref=FexRss&amp;aid=&amp;tid=1&amp;url=https%3a%2f%2fwww.reuters.com%2fmarkets%2fwaller&amp;c=1</link>
    <description>Waller said...</description><pubDate>Wed, 14 Oct 2026 20:15:00 GMT</pubDate><News:Source>Reuters</News:Source></item></channel></rss>`;
  assert.deepEqual(parseBingNews(bing), [{ title: "Fed's Waller: cuts & patience", url: 'https://www.reuters.com/markets/waller', publisher: 'Reuters', published_at: '2026-10-14T20:15:00.000Z', snippet: 'Waller said...' }]);
  const ddg = `<div class="result results_links results_links_deep web-result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.federalreserve.gov%2Fnewsevents%2Fpressreleases.htm&amp;rut=x">Federal Reserve <b>press</b> releases</a>
    <a class="result__snippet" href="x">Official <b>statements</b></a></div>`;
  assert.deepEqual(parseDuckDuckGo(ddg), [{ title: 'Federal Reserve press releases', url: 'https://www.federalreserve.gov/newsevents/pressreleases.htm', snippet: 'Official statements' }]);
});

test('headline search matches most terms, prefers title hits and respects the lookback', () => {
  const now = Date.parse('2026-10-14T20:00:00Z');
  const records = {
    a: { title: 'Explosion in Riyadh after missile attack', summary: 'Oil facilities reported damaged', publisher: 'IRNA', url: 'https://a.example', stamp: now - 3600000 },
    b: { title: 'Oil steady', summary: 'Riyadh missile explosion reports unconfirmed', publisher: 'Reuters', url: 'https://b.example', stamp: now - 7200000 },
    c: { title: 'Riyadh missile explosion', summary: '', publisher: 'Old', url: 'https://c.example', stamp: now - 100 * 3600000 },
    d: { title: 'Fed holds rates', summary: '', publisher: 'AP', url: 'https://d.example', stamp: now },
  };
  assert.deepEqual(searchArchive(records, 'Riyadh missile explosion', { now }).map(r => r.publisher), ['IRNA', 'Reuters']);
  assert.deepEqual(searchArchive(records, 'Riyadh missile explosion', { now, hours: 168 }).map(r => r.publisher), ['IRNA', 'Old', 'Reuters']);
});

test('answer queue takes open events first and retries stale unresolved ones only while recent', () => {
  const now = Date.parse('2026-10-14T20:00:00Z');
  const queue = answerQueue([
    { id: 'open', status: 'open', created_at: '2026-10-14T19:00:00Z' },
    { id: 'done', status: 'answered', created_at: '2026-10-14T10:00:00Z', answer: { verdict: 'confirmed', answered_at: '2026-10-14T11:00:00Z' } },
    { id: 'retry', status: 'answered', created_at: '2026-10-14T10:00:00Z', answer: { verdict: 'unresolved', answered_at: '2026-10-14T11:00:00Z' } },
    { id: 'fresh', status: 'answered', created_at: '2026-10-14T18:00:00Z', answer: { verdict: 'unresolved', answered_at: '2026-10-14T19:00:00Z' } },
    { id: 'old', status: 'answered', created_at: '2026-10-11T10:00:00Z', answer: { verdict: 'unresolved', answered_at: '2026-10-11T11:00:00Z' } },
  ], now);
  assert.deepEqual(queue.map(q => q.id), ['open', 'retry']);
});
