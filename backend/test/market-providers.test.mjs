import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { D1 } from '../node/server.mjs';

const source = (await build({ entryPoints: ['src/market-providers.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
const { twelveQuote, quoteStatus, providerData, twelve } = await import(`data:text/javascript,${encodeURIComponent(source)}`);
const quotesSource = (await build({ entryPoints: ['src/quotes.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
const { newestQuote, quote, shape } = await import(`data:text/javascript,${encodeURIComponent(quotesSource)}`);
const dataSource = (await build({ entryPoints: ['src/data.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
const { runTool, catalogJSON } = await import(`data:text/javascript,${encodeURIComponent(dataSource)}`);
const now = Date.parse('2026-10-26T15:00:00Z');
const sample = { symbol: 'AAPL', name: 'Apple', exchange: 'NASDAQ', currency: 'USD', datetime: '2026-10-26', close: '110', previous_close: '100', last_quote_at: (now - 60000) / 1000 };
const shaped = (changes = {}, at = now) => twelveQuote({ ...sample, ...changes }, 'AAPL', new Date(at).toISOString(), at);

async function env() {
  const DB = new D1(':memory:');
  await DB.exec(await readFile('migrations/0020_market_data.sql', 'utf8'));
  return { DB, TWELVE_DATA_API_KEY: 'test-only', MASSIVE_API_KEY: 'test-only', FMP_API_KEY: 'test-only' };
}

test('Twelve Data preserves observed and fetched times and computes the supplied baseline', () => {
  const q = shaped();
  assert.equal(q.price, 110);
  assert.equal(q.previousClose, 100);
  assert.equal(q.changePercent, 10);
  assert.equal(q.time, new Date(now - 60000).toISOString());
  assert.equal(q.fetchedAt, new Date(now).toISOString());
  assert.equal(q.source, 'Twelve Data');
  assert.equal(q.dataStatus, 'current');
  assert.deepEqual(q.points, []);
});

test('missing, zero, blank and malformed baselines are unavailable, not neutral', () => {
  for (const previous_close of [undefined, null, '', ' ', '0', '-1', 'NaN']) assert.equal(shaped({ previous_close }), null);
  for (const close of [undefined, null, '', 'Infinity', '-1']) assert.equal(shaped({ close }), null);
  assert.equal(shaped({ previous_close: '110' }).changePercent, 0);
});

test('timestamps must be real, in the reported regular session, and not in the future', () => {
  assert.equal(shaped({ last_quote_at: undefined }), null);
  assert.equal(shaped({ last_quote_at: (now + 120000) / 1000 }), null);
  assert.equal(shaped({ datetime: '2026-10-23' }), null);
  assert.equal(shaped({ exchange: 'LSE', currency: 'GBp' }), null);
});

test('a successful response with old prices remains stale', () => {
  const q = shaped({ datetime: '2026-10-23', last_quote_at: Date.parse('2026-10-23T19:59:00Z') / 1000 });
  assert.equal(q.dataStatus, 'stale');
  assert.equal(q.fetchedAt, new Date(now).toISOString());
  assert.equal(q.time, '2026-10-23T19:59:00.000Z');
});

test('calendar handles weekends, holidays and early close without fabricating a new session', () => {
  assert.equal(quoteStatus(Date.parse('2026-10-23T19:59:00Z'), Date.parse('2026-10-26T12:00:00Z')), 'closed');
  assert.equal(quoteStatus(Date.parse('2026-11-25T20:59:00Z'), Date.parse('2026-11-26T16:00:00Z')), 'closed');
  assert.equal(quoteStatus(Date.parse('2026-11-27T17:59:00Z'), Date.parse('2026-11-27T19:00:00Z')), 'closed');
  assert.equal(quoteStatus(Date.parse('2026-11-27T15:00:00Z'), Date.parse('2026-11-27T19:00:00Z')), 'stale');
});

test('newest valid observation wins, independent of provider priority', () => {
  const td = shaped();
  const yahoo = { ...td, source: 'Yahoo Finance', time: new Date(now - 30000).toISOString(), price: 111 };
  assert.equal(newestQuote([yahoo, td], now).source, 'Yahoo Finance');
  assert.equal(newestQuote([td, yahoo], now).source, 'Yahoo Finance');
  assert.equal(newestQuote([null, td], now).source, 'Twelve Data');
  assert.equal(newestQuote([null, null], now), null);
});

test('Yahoo quotes without source observation time are unavailable', () => {
  assert.equal(shape({ meta: { symbol: 'AAPL', regularMarketPrice: 110, previousClose: 100 } }), null);
});

test('persistent provider cache retains fetch time and coalesces identical concurrent requests', async () => {
  const e = await env(), original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls++; return Response.json(sample); };
  try {
    const results = await Promise.all(Array.from({ length: 5 }, () => providerData(e, 'twelve', 'same', '/quote?symbol=AAPL', 120)));
    assert.equal(calls, 1);
    const cached = await providerData(e, 'twelve', 'same', '/quote?symbol=AAPL', 120);
    assert.equal(calls, 1);
    assert.equal(cached.fetchedAt, results[0].fetchedAt);
    assert.equal(cached.data.last_quote_at, sample.last_quote_at);
  } finally { globalThis.fetch = original; e.DB.db.close(); }
});

test('minute and daily budgets are enforced atomically across different symbols', async () => {
  const e = await env(), original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls++; return Response.json(sample); };
  try {
    await Promise.all(Array.from({ length: 12 }, (_, i) => providerData(e, 'twelve', `symbol-${i}`, '/quote', 120)));
    assert.equal(calls, 7);
    await e.DB.prepare('UPDATE market_data_usage SET day_used = 760, minute = 0').run();
    assert.equal(await providerData(e, 'twelve', 'over-daily', '/quote', 120), null);
    assert.equal(calls, 7);
  } finally { globalThis.fetch = original; e.DB.db.close(); }
});

test('upstream errors do not cache false success; recovery retries after failure', async () => {
  const e = await env(), original = globalThis.fetch;
  let healthy = false, calls = 0;
  globalThis.fetch = async () => { calls++; return healthy ? Response.json(sample) : Response.json({ status: 'error', code: 429 }); };
  try {
    assert.equal(await providerData(e, 'twelve', 'recover', '/quote', 120), null);
    healthy = true;
    assert.ok(await providerData(e, 'twelve', 'recover', '/quote', 120));
    assert.equal(calls, 2);
  } finally { globalThis.fetch = original; e.DB.db.close(); }
});

test('unsupported futures and indices do not consume Twelve Data credits', async () => {
  const e = await env(), original = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error('Must not request'); };
  try {
    assert.equal(await twelve(e, 'ES=F'), null);
    assert.equal(await twelve(e, '^GSPC'), null);
    assert.equal(await twelve(e, 'BTC-USD'), null);
    assert.equal(await e.DB.prepare('SELECT * FROM market_data_usage').first(), null);
  } finally { globalThis.fetch = original; e.DB.db.close(); }
});

test('reference tools publish capabilities, preserve zero and distinguish fetch time from freshness', async () => {
  const e = await env(), original = globalThis.fetch;
  const contract = { ticker: 'O:AAPL261030C00100000', underlying_ticker: 'AAPL', contract_type: 'call', expiration_date: '2026-10-30', strike_price: 100, shares_per_contract: 100 };
  globalThis.fetch = async url => String(url).includes('financialmodelingprep')
    ? Response.json([{ symbol: 'AAPL', companyName: 'Apple', sector: 'Technology', beta: 0, marketCap: 0, currency: 'USD' }])
    : Response.json({ status: 'OK', results: [contract, { ...contract, underlying_ticker: 'MSFT' }], next_url: 'https://api.massive.com/next?apiKey=must-not-be-stored' });
  try {
    const catalog = JSON.stringify(catalogJSON('https://example.test'));
    assert.match(catalog, /stock_options/);
    assert.match(catalog, /stock_profile/);
    const profile = await runTool('stock_profile', { symbol: 'AAPL' }, e);
    assert.equal(profile.sections[0].rows.find(r => r.label === 'Beta').value, '0.000');
    assert.match(profile.note, /Source observation times are unavailable/);
    assert.match(profile.note, new RegExp(profile.as_of.replaceAll('.', '\\.')));
    const options = await runTool('stock_options', { symbol: 'AAPL' }, e);
    assert.equal(options.sections[0].rows.length, 1);
    assert.match(options.note, /Partial chain/);
    assert.match(options.note, /No live prices/);
    assert.doesNotMatch(JSON.stringify(await e.DB.prepare('SELECT body FROM market_data_cache').all()), /must-not-be-stored/);
    await assert.rejects(runTool('stock_options', { symbol: 'AAPL', expiration: '2026-02-30' }, e), /Invalid expiration/);
    await assert.rejects(runTool('stock_profile', { symbol: 'ES=F' }, e), /Invalid US stock/);
  } finally { globalThis.fetch = original; e.DB.db.close(); }
});

test('reference errors recover, empty chains stay empty and exhausted budgets stay unavailable', async () => {
  const e = await env(), original = globalThis.fetch;
  let healthy = false;
  globalThis.fetch = async url => String(url).includes('financialmodelingprep')
    ? healthy ? Response.json([{ symbol: 'AAPL' }]) : Response.json({ 'Error Message': 'unavailable' })
    : healthy ? Response.json({ status: 'OK', results: [] }) : new Response('', { status: 403 });
  try {
    await assert.rejects(runTool('stock_options', { symbol: 'AAPL' }, e), /unavailable/);
    await assert.rejects(runTool('stock_profile', { symbol: 'AAPL' }, e), /unavailable/);
    healthy = true;
    const empty = await runTool('stock_options', { symbol: 'AAPL' }, e);
    assert.equal(empty.sections[0].rows.length, 0);
    assert.match(empty.sections[0].title, /No matching contracts/);
    assert.ok(await runTool('stock_profile', { symbol: 'AAPL' }, e));
    await e.DB.prepare('UPDATE market_data_usage SET day_used = 230, minute = 0 WHERE provider = ?').bind('fmp').run();
    await assert.rejects(runTool('stock_profile', { symbol: 'MSFT' }, e), /unavailable/);
    await e.DB.prepare('UPDATE market_data_cache SET expires_at = 0').run();
    await providerData(e, 'twelve', 'cleanup', '/quote', 120);
    assert.equal((await e.DB.prepare('SELECT COUNT(*) AS n FROM market_data_cache WHERE expires_at = 0').first()).n, 0);
  } finally { globalThis.fetch = original; e.DB.db.close(); }
});

test('Yahoo failure recovers through Twelve Data; a Twelve failure preserves Yahoo', async () => {
  const e = await env(), original = globalThis.fetch;
  const stamp = Math.floor(Date.now() / 1000);
  const td = { ...sample, datetime: '2026-10-23', last_quote_at: Date.parse('2026-10-23T19:59:00Z') / 1000 };
  let yahooFails = true, twelveFails = false;
  globalThis.fetch = async url => {
    if (String(url).includes('twelvedata')) return twelveFails ? new Response('', { status: 429 }) : Response.json(td);
    return yahooFails ? new Response('', { status: 429 }) : Response.json({ chart: { result: [{ meta: { symbol: 'MSFT', currency: 'USD', exchangeName: 'NasdaqGS', regularMarketPrice: 200, previousClose: 190, regularMarketTime: stamp } }] } });
  };
  try {
    assert.equal((await quote('AAPL', e)).source, 'Twelve Data');
    yahooFails = false; twelveFails = true;
    assert.equal((await quote('MSFT', e)).source, 'Yahoo Finance');
  } finally { globalThis.fetch = original; e.DB.db.close(); }
});
