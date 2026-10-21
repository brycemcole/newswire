import { test } from 'node:test';
import assert from 'node:assert/strict';

process.env.NEWSWIRE_WRITER_TOKEN = 'test-only';
const { checks, run, publisherFreshness } = await import('../../scripts/smoke/check.mjs');

test('publisher freshness uses actual receipts, ignores future/invalid times and unrelated rules', () => {
  const now = Date.parse('2026-10-20T03:00:00Z');
  const story = (received_at, tags = ['headlines']) => ({ received_at, tags, published_at: '2026-10-19T00:00:00Z' });
  assert.equal(publisherFreshness({ stories: [story('2026-10-20T02:59:00Z')] }, now), null);
  assert.equal(publisherFreshness({ stories: [story('2026-10-19T15:00:00Z'), story('2026-10-20T03:00:00Z', ['markets'])] }, now), 'publisher feed stale: latest receipt 12.0 hours ago');
  assert.match(publisherFreshness({ stories: [story('invalid'), story('2026-10-21T00:00:00Z')] }, now), /no valid publisher/);
  assert.equal(publisherFreshness({ stories: [story('2026-10-19T15:00:00Z'), story('2026-10-20T02:00:00Z')] }, now), null);
});

test('HTTP 200 stale publisher feed fails and recovers on a new receipt', async () => {
  const selected = [checks[1]];
  let receipt = new Date(Date.now() - 12 * 3600000).toISOString();
  const fake = async () => Response.json({ stories: [{ tags: ['headlines'], received_at: receipt }] });
  const stale = await run(fake, selected);
  assert.equal(stale[0].ok, false);
  assert.match(stale[0].error, /publisher feed stale/);
  receipt = new Date().toISOString();
  assert.equal((await run(fake, selected))[0].ok, true);
});

test('production check flags HTTP errors, bad shapes and timeouts per app request', async () => {
  const fake = async url => {
    const path = new URL(url).pathname + new URL(url).search;
    if (path.includes('QQQ&history')) return new Response(JSON.stringify({ error: { message: 'Worker exceeded resource limits' } }), { status: 503 });
    if (path.startsWith('/v1/stories')) return Response.json({ stories: [{ id: 1, tags: ['headlines'], received_at: new Date().toISOString() }] });
    if (path.startsWith('/v1/market-pulse')) return Response.json({ symbol: new URL(url).searchParams.get('symbol'), status: 'available', history: [] });
    if (path === '/v1/research?symbol=SPY') return Response.json({ symbol: 'SPY', performance: {} });
    return Response.json({ symbol: 'QQQ', performance: {}, agent: { board: [], questions: [] } });
  };
  const results = await run(fake);
  assert.equal(results.length, checks.length);
  assert.deepEqual(results.filter(r => !r.ok).map(r => [r.name, r.error]), [
    ['Outlook QQQ', 'HTTP 503: Worker exceeded resource limits'], ['Research SPY', 'unexpected response shape']]);
});
