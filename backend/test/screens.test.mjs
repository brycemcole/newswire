import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const bundle = async entry => import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: [entry], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const { lastCompletedSession, windowReturn, parseRating, upcomingEarnings, tally } = await bundle('src/screens.ts');
const { runTool } = await bundle('src/data.ts');

const day = 86400;
const et = (date, hour, minute = 0) => new Date(`${date}T${String(hour + 5).padStart(2, '0')}:${String(minute).padStart(2, '0')}:00Z`).getTime(); // EST dates only

test('last completed session follows holidays and early closes', () => {
  // Thanksgiving 2026 is Nov 26; Nov 27 closes at 1 pm ET.
  assert.equal(lastCompletedSession(et('2026-11-27', 12)).date, '2026-11-25');
  assert.equal(lastCompletedSession(et('2026-11-27', 13, 30)).date, '2026-11-27');
  assert.equal(lastCompletedSession(et('2026-11-28', 10)).date, '2026-11-27');
});

const bars = (end, count, step = day) => Array.from({ length: count }, (_, i) => end - (count - 1 - i) * step);
// Weekday bars covering 91 calendar days, like a 3-month daily series.
const weekdays = end => { const out = []; for (let t = end; t > end - 91 * day; t -= day) if (![0, 6].includes(new Date(t * 1000).getUTCDay())) out.unshift(t); return out; };
const now = et('2026-11-25', 18);
const session = lastCompletedSession(now);

test('three-month return needs current prices and a baseline near the window start', () => {
  const stamps = weekdays(session.open);
  const closes = stamps.map((_, i) => 100 + i);
  const ok = windowReturn(stamps, closes, now, 91, session);
  assert.equal(ok.ok, true);
  assert.equal(ok.value.fromPrice, 100);
  assert.equal(ok.value.to, session.open);
  assert.equal(ok.value.toPrice, 100 + stamps.length - 1);
  // Nulls are skipped rather than read as zero.
  assert.equal(windowReturn(stamps, closes.map((c, i) => i === 0 ? null : c), now, 91, session).value.fromPrice, 101);
  assert.equal(windowReturn(weekdays(session.open - 5 * day), closes, now, 91, session).reason, 'stale prices');
  assert.equal(windowReturn(bars(session.open, 20), closes.slice(0, 20), now, 91, session).reason, 'under 3 months of history');
  assert.equal(windowReturn([session.open], [100], now, 91, session).reason, 'no price history');
  assert.equal(windowReturn(stamps, stamps.map(() => 0), now, 91, session).reason, 'no price history');
});

test('rating and earnings helpers keep unavailable apart from out of range', () => {
  assert.deepEqual(parseRating('1.8 - Buy'), { score: 1.8, label: 'Buy' });
  assert.equal(parseRating('2.0 - Strong Buy').label, 'Strong Buy');
  assert.equal(parseRating(undefined), null);
  assert.equal(parseRating('-'), null);
  const seconds = now / 1000;
  assert.equal(upcomingEarnings({}, now, 14).reason, 'no earnings date');
  assert.equal(upcomingEarnings({ earningsTimestamp: seconds - day }, now, 14).reason, 'last report only, next date not set');
  assert.equal(upcomingEarnings({ earningsTimestamp: seconds + 20 * day }, now, 14).reason, 'after window');
  assert.deepEqual(upcomingEarnings({ earningsTimestamp: seconds + 2 * day, earningsTimestampStart: seconds + 2 * day, earningsTimestampEnd: seconds + 5 * day }, now, 14).value,
    { at: seconds + 2 * day, start: seconds + 2 * day, end: seconds + 5 * day });
  assert.deepEqual(tally(['a', 'b', 'a']), [{ reason: 'a', count: 2 }, { reason: 'b', count: 1 }]);
});

// Tool-level: the Yahoo screener and spark endpoints are replaced; the crumb session answers every request.
function yahoo({ quotes, spark }) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    if (url.includes('fc.yahoo.com')) return new Response('', { headers: { 'set-cookie': 'A=1; Path=/' } });
    if (url.includes('getcrumb')) return new Response('crumb');
    if (url.includes('/screener')) return Response.json({ finance: { result: [{ total: quotes.length, quotes }] } });
    if (url.includes('/spark')) return spark(url);
    throw new Error(`unexpected ${url}`);
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}
const run = (preset, args = {}) => runTool('stock_screens', { preset, ...args }, {});
const fresh = Math.floor(Date.now() / 1000) - 60;
const q = (symbol, extra = {}) => ({ symbol, longName: `${symbol} Inc`, regularMarketPrice: 100, regularMarketChangePercent: 1.5, regularMarketTime: fresh, marketCap: 50e9, ...extra });

test('analyst_buy ranks Buy or better and counts companies without a rating', async () => {
  const mock = yahoo({ quotes: [q('AAA', { averageAnalystRating: '2.0 - Buy' }), q('BBB', { averageAnalystRating: '1.4 - Strong Buy' }), q('CCC', { averageAnalystRating: '3.1 - Hold' }), q('DDD'), q('EEE.L', { averageAnalystRating: '1.0 - Strong Buy' })] });
  try {
    const result = await run('analyst_buy');
    assert.deepEqual(result.sections[0].rows.map(r => r.symbol), ['BBB', 'AAA']);
    assert.match(result.sections[0].rows[0].value, /^Strong Buy · 1\.4$/);
    assert.match(result.note, /2 of 3 rated companies in the 4 largest/);
    assert.match(result.note, /1 no consensus rating/);
    assert.equal(result.as_of, new Date(Math.floor(fresh) * 1000).toISOString());
    assert.doesNotMatch(result.note, /out of date/);
  } finally { mock.restore(); }
});

test('screens flag a pool whose newest quote predates the last session', async () => {
  const old = Math.floor(Date.now() / 1000) - 10 * day;
  const mock = yahoo({ quotes: [q('AAA', { averageAnalystRating: '2.0 - Buy', regularMarketTime: old })] });
  try {
    const result = await run('analyst_buy');
    assert.equal(result.as_of, new Date(Math.floor(old) * 1000).toISOString());
    assert.match(result.note, /may be out of date/);
  } finally { mock.restore(); }
});

test('earnings_soon lists future dates in order and separates ranges and missing dates', async () => {
  const seconds = Math.floor(Date.now() / 1000);
  const mock = yahoo({ quotes: [
    q('LATE', { earningsTimestamp: seconds + 6 * day }),
    q('SOON', { earningsTimestamp: seconds + 2 * day }),
    q('RNG', { earningsTimestamp: seconds + 3 * day, earningsTimestampStart: seconds + 3 * day, earningsTimestampEnd: seconds + 8 * day }),
    q('PAST', { earningsTimestamp: seconds - 30 * day }),
    q('FAR', { earningsTimestamp: seconds + 40 * day }),
    q('NONE'),
  ] });
  try {
    const result = await run('earnings_soon', { days: 14 });
    const rows = result.sections[0].rows;
    assert.deepEqual(rows.map(r => r.symbol), ['SOON', 'RNG', 'LATE']);
    assert.match(rows[1].detail, /Date range, not confirmed/);
    assert.equal(rows[0].date, new Date(Math.floor(seconds + 2 * day) * 1000).toISOString());
    assert.match(result.note, /1 last report only, next date not set/);
    assert.match(result.note, /1 no earnings date/);
    assert.doesNotMatch(result.note, /after window/);
    assert.equal((await run('earnings_soon', { days: 45 }).catch(e => e)).status, 400);
  } finally { mock.restore(); }
});

test('momentum_3m ranks by true window return, drops stale and short history, and survives a failed batch', async () => {
  const session = lastCompletedSession(Date.now());
  const stamps = weekdays(session.open);
  const history = (symbol, end, start, shift = 0) => ({ symbol, response: [{ timestamp: end ?? stamps, indicators: { quote: [{ close: (end ?? stamps).map((_, i) => start + i * shift) }] } }] });
  const symbols = Array.from({ length: 25 }, (_, i) => `S${String(i).padStart(2, '0')}`);
  const quotes = symbols.map(s => q(s));
  const spark = url => {
    const asked = decodeURIComponent(new URL(url).searchParams.get('symbols')).split(',');
    if (asked.includes('S20')) return new Response('down', { status: 502 }); // second batch fails
    return Response.json({ spark: { result: asked.map(s => s === 'S00' ? history(s, stamps, 100, 1)
      : s === 'S01' ? history(s, stamps, 100, 0.5)
      : s === 'S02' ? history(s, stamps.map(t => t - 6 * day), 100, 2)
      : s === 'S03' ? history(s, stamps.slice(40), 100, 2)
      : history(s, stamps, 100, 0.1)) } });
  };
  const mock = yahoo({ quotes, spark });
  try {
    const result = await run('momentum_3m', { limit: 3 });
    const rows = result.sections[0].rows;
    assert.deepEqual(rows.map(r => r.symbol), ['S00', 'S01', 'S04']);
    assert.equal(rows[0].change, Math.round((stamps.length - 1) / 100 * 10000) / 100);
    assert.equal(rows[0].change_label, '3 MO');
    assert.equal(rows[0].date, new Date(session.open * 1000).toISOString());
    assert.equal(result.as_of, new Date(session.open * 1000).toISOString());
    assert.match(result.note, /1 stale prices/);
    assert.match(result.note, /1 under 3 months of history/);
    assert.match(result.note, /5 price history unavailable/);
    assert.match(result.note, /18 had enough current history to rank/);
    assert.match(result.note, /may not be in this pool/);
  } finally { mock.restore(); }
});

test('screens reject unknown presets and report an empty candidate pool as an error', async () => {
  assert.equal((await run('bogus').catch(e => e)).status, 400);
  assert.equal((await runTool('stock_screens', {}, {}).catch(e => e)).status, 400);
  const mock = yahoo({ quotes: [] });
  try { assert.equal((await run('analyst_buy').catch(e => e)).status, 502); } finally { mock.restore(); }
});
