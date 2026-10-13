import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const { targetPrices } = await import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: ['src/research-prices.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
test('target baselines use completed bars and retain provenance without treating an unfinished bar as observable', () => {
  const now = Date.parse('2026-10-13T11:02:00Z');
  const times = ['2026-10-12T19:55:00Z', '2026-10-13T10:55:00Z', '2026-10-13T11:00:00Z'].map(time => Date.parse(time) / 1000);
  const archive = { url: 'https://query1.finance.yahoo.com/v8/finance/chart/SPY', retrieved_at: new Date(now).toISOString(), payload: { chart: { result: [{ timestamp: times, indicators: { quote: [{ close: [100, 99, 888] }] } }] } } };
  const prices = targetPrices(archive, now);
  assert.equal(prices.previous_close, 100);
  assert.equal(prices.previous_close_at, '2026-10-12T20:00:00.000Z');
  assert.equal(prices.price, 99);
  assert.equal(prices.price_at, '2026-10-13T11:00:00.000Z');
  assert.equal(prices.observed_at, archive.retrieved_at);
});
