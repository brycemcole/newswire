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
