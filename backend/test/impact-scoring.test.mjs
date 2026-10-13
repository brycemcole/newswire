import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const { scoreImpacts } = await import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: ['src/market-pulse.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const now = Date.parse('2026-10-13T14:00:00Z');
const item = { id: 'one', title: 'Fed cuts rates by 25 basis points', source: 'Wire', url: 'https://example.com', published_at: '2026-10-13T12:00:00Z', received_at: '2026-10-13T12:01:00Z', classified_at: '2026-10-13T12:02:00Z', direction: 1, channel: 'rates', size: 'major', confidence: 0.9 };
test('repeated impact titles cannot amplify or rejuvenate the event', () => {
  const copies = Array.from({ length: 30 }, (_, i) => ({ ...item, id: `copy-${i}`, source: `Outlet ${i}`, received_at: '2026-10-13T13:59:00Z' }));
  const base = scoreImpacts([item], now, 'SPY');
  assert.deepEqual(scoreImpacts([...copies, item], now, 'SPY'), { ...base, classified: 31 });
  assert.deepEqual(scoreImpacts([item, ...copies].reverse(), now, 'SPY'), { ...base, classified: 31 });
});
test('same-day midnight placeholders decay from receipt without reviving old dated articles', () => {
  const midnight = scoreImpacts([{ ...item, published_at: '2026-10-13T00:00:00Z' }], now, 'SPY');
  const fresh = scoreImpacts([{ ...item, published_at: item.received_at }], now, 'SPY');
  assert.equal(midnight.points, fresh.points);
  assert.equal(scoreImpacts([{ ...item, published_at: '2026-10-10T00:00:00Z' }], now, 'SPY').points, 0);
  assert.equal(scoreImpacts([{ ...item, classified_at: '2026-10-13T14:01:00Z' }], now, 'SPY').points, 0);
});
