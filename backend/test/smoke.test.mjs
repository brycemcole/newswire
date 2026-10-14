import { test } from 'node:test';
import assert from 'node:assert/strict';

process.env.NEWSWIRE_WRITER_TOKEN = 'test-only';
const { checks, run } = await import('../../scripts/smoke/check.mjs');

test('production check flags HTTP errors, bad shapes and timeouts per app request', async () => {
  const fake = async url => {
    const path = new URL(url).pathname + new URL(url).search;
    if (path.includes('QQQ&history')) return new Response(JSON.stringify({ error: { message: 'Worker exceeded resource limits' } }), { status: 503 });
    if (path.startsWith('/v1/stories')) return Response.json({ stories: [{ id: 1 }] });
    if (path.startsWith('/v1/market-pulse')) return Response.json({ symbol: new URL(url).searchParams.get('symbol'), status: 'available', history: [] });
    if (path === '/v1/research?symbol=SPY') return Response.json({ symbol: 'SPY', performance: {} });
    return Response.json({ symbol: 'QQQ', performance: {}, agent: { board: [], questions: [] } });
  };
  const results = await run(fake);
  assert.equal(results.length, checks.length);
  assert.deepEqual(results.filter(r => !r.ok).map(r => [r.name, r.error]), [
    ['Outlook QQQ', 'HTTP 503: Worker exceeded resource limits'], ['Research SPY', 'unexpected response shape']]);
});
