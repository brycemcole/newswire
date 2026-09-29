import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const source = (await build({ entryPoints: ['src/quotes.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
const { candidates, accepts, shape } = await import(`data:text/javascript,${encodeURIComponent(source)}`);

test('company names only match the listed company', () => {
  assert.ok(candidates("SK Hynix Shares Fall as Solidigm's Potential US IPO Sours Mood").includes('SK Hynix'));
  assert.ok(candidates('Stocks Rise as Nvidia Jumps and Bank of America Gains').includes('Bank of America'));
  assert.ok(!candidates('Trump Says Fed Should Cut After Wall Street Slides').some(phrase => ['Trump', 'Fed', 'Wall Street'].includes(phrase)));
  assert.ok(candidates('Allied Blenders and Distillers Extends Rally Amid Possible Sale').includes('Allied Blenders and Distillers'));
  assert.ok(accepts('Allied Blenders and Distillers', 'Allied Blenders and Distillers Limited'));
  assert.ok(accepts('SK Hynix Inc.', 'SK hynix Inc.'));
  assert.ok(accepts('Apple', 'Apple Inc.'));
  assert.ok(accepts('SK Hynix Shares', 'SK hynix Inc.'));
  assert.ok(!accepts('Trump', 'Trump Media & Technology Group Corp.'));
  assert.ok(!accepts('Fed', 'FedEx Corporation'));
  assert.ok(!candidates('Bill Gates Says Trump Is Wrong').includes('Bill'));
  assert.ok(!accepts('City', 'City Holding Company'));
  assert.ok(accepts('UBS', 'UBS Group AG'));
});

test('quote shape separates the regular session from after hours', () => {
  const period = (start, end) => ({ start, end });
  const chart = {
    meta: { symbol: 'NVDA', shortName: 'NVIDIA Corporation', currency: 'USD', fullExchangeName: 'NasdaqGS', regularMarketPrice: 110, previousClose: 100, regularMarketTime: 2000, hasPrePostMarketData: true,
      currentTradingPeriod: { pre: period(500, 1000), regular: period(1000, 2000), post: period(2000, 3000) } },
    timestamp: [600, 1000, 1500, 1990, 2100, 2500],
    indicators: { quote: [{ close: [99, 101, 105, 110, 111, 112] }] },
  };
  const post = shape(chart, 2600);
  assert.equal(post.state, 'post');
  assert.equal(post.changePercent, 10);
  assert.deepEqual(post.extended, { session: 'post', price: 112, change: 2, changePercent: 1.8182, time: new Date(2500000).toISOString() });
  assert.deepEqual(post.points, [101, 105, 110]);
  assert.deepEqual(post.extendedPoints, [111, 112]);
  const open = shape(chart, 1500);
  assert.equal(open.state, 'regular');
  assert.equal(open.extended, null);
  assert.equal(shape({ meta: { symbol: 'X' } }), null);
});
