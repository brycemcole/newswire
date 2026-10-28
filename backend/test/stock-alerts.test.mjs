import { test } from 'node:test';
import assert from 'node:assert/strict';
import { movements } from '../../scripts/monitor/stock-alerts.mjs';
const now = Date.parse('2026-09-30T15:00:00Z');
const quote = price => ({ price, previousClose: 100, at: now, zone: 'America/New_York' });
test('5 and 10 percent in both directions, dedup and stale rejection', () => {
  for (const price of [105, 110, 95, 90]) {
    const state = {};
    const events = movements('AAPL', quote(price), state, now);
    assert.equal(events.length, 1);
    for (const key of events[0].marks) state[key] = { at: new Date(now).toISOString() };
    assert.equal(movements('AAPL', quote(price), state, now).length, 0);
  }
  assert.equal(movements('AAPL', quote(104), {}, now).length, 0);
  assert.equal(movements('AAPL', quote(110), {}, now + 600000).length, 0);
});
test('rapid movement uses recent samples and cooldown', () => {
  const state = {};
  movements('AAPL', { ...quote(100), at: now - 180000 }, state, now - 180000);
  const event = movements('AAPL', quote(103), state, now)[0];
  assert.match(event.title, /moving fast/);
  state[event.key] = { at: new Date(now).toISOString() };
  assert.equal(movements('AAPL', { ...quote(103), at: now + 60000 }, state, now + 60000).length, 0);
});

test('custom targets accept equality, both directions and reject stale or invalid prices', async () => {
  const { targetReached, activityPayload } = await import('../../scripts/monitor/stock-alerts.mjs');
  for (const direction of ['above', 'below']) {
    const watch = { id: 'test', symbol: 'AAPL261218C00250000', target: 5, direction };
    assert.equal(targetReached(watch, quote(5), now), true);
    assert.equal(targetReached(watch, quote(direction === 'above' ? 6 : 4), now), true);
    assert.equal(targetReached(watch, quote(direction === 'above' ? 4 : 6), now), false);
    assert.equal(targetReached(watch, quote(5), now + 300001), false);
    assert.equal(targetReached(watch, { ...quote(5), at: now + 60001 }, now), false);
    assert.equal(targetReached(watch, quote(NaN), now), false);
    const payload = activityPayload(watch, { ...quote(5), currency: 'USD' }, now);
    assert.equal(payload.aps['content-state'].quotedAt + 978307200, now / 1000);
    assert.equal(payload.aps['content-state'].reached, true);
    assert.equal(payload.aps['stale-date'], now / 1000 + 300);
  }
});


test('live quotes select the newest timestamped observation and normalize currency', async () => {
  const { quoteFromChart } = await import('../../scripts/monitor/stock-alerts.mjs');
  const chart = { meta: { currency: 'GBp', chartPreviousClose: 10000, regularMarketPrice: 10300, regularMarketTime: now / 1000 }, timestamp: [(now - 60000) / 1000], indicators: { quote: [{ close: [10200] }] } };
  assert.equal(quoteFromChart(chart, now).price, 103);
  assert.equal(quoteFromChart(chart, now).at, now);
  assert.equal(quoteFromChart(chart, now).previousClose, 100);
  assert.equal(quoteFromChart(chart, now).currency, 'GBP');
  chart.timestamp.push((now + 1000) / 1000);
  chart.indicators.quote[0].close.push(10400);
  assert.equal(quoteFromChart(chart, now).price, 104);
  assert.equal(quoteFromChart(chart, now).at, now + 1000);
  chart.meta.regularMarketTime = (now + 120000) / 1000;
  assert.equal(quoteFromChart(chart, now).at, now + 1000);
  delete chart.meta.chartPreviousClose;
  assert.equal(quoteFromChart(chart, now).previousClose, null);
  delete chart.meta.regularMarketTime;
  assert.equal(quoteFromChart(chart, now).at, now + 1000);
  assert.throws(() => quoteFromChart({ meta: { regularMarketPrice: 100 } }, now), /timestamped/);
});

test('percentage watches require fresh quotes and a valid baseline, cross and rearm with cooldown', async () => {
  const { watchMovement } = await import('../../scripts/monitor/stock-alerts.mjs');
  for (const [direction, price] of [['above', 101], ['below', 99], ['either', 99]]) {
    const watch = { id: direction, symbol: 'SPY', percent: 1, direction };
    const state = {};
    assert.equal(watchMovement(watch, quote(price), state, now).length, 1);
    assert.equal(watchMovement(watch, { ...quote(price), previousClose: null }, state, now).length, 0);
    assert.equal(watchMovement(watch, { ...quote(price), previousClose: Infinity }, state, now).length, 0);
    assert.equal(watchMovement(watch, quote(price), state, now + 300001).length, 0);
    assert.equal(watchMovement(watch, { ...quote(price), at: now + 60001 }, state, now).length, 0);
    const event = watchMovement(watch, quote(price), state, now)[0];
    state[event.key] = { at: new Date(now).toISOString(), quoteAt: now, armed: false };
    assert.equal(watchMovement(watch, quote(price), state, now).length, 0);
    watchMovement(watch, { ...quote(100), at: now - 1000 }, state, now);
    assert.equal(state[event.key].armed, false);
    watchMovement(watch, { ...quote(100), at: now + 60000 }, state, now + 60000);
    assert.equal(state[event.key].armed, true);
    assert.equal(watchMovement(watch, { ...quote(price), at: now + 120000 }, state, now + 120000).length, 0);
    assert.equal(watchMovement(watch, { ...quote(price), at: now + 1800000 }, state, now + 1800000).length, 1);
    assert.equal(watchMovement(watch, { ...quote(price), at: now + 86400000 }, state, now + 86400000).length, 1);
  }
});
