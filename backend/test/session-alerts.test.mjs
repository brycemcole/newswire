import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { sessionAlertEvents } from '../../scripts/monitor/session-alerts.mjs';
const bundle = await build({ entryPoints: ['src/market-session.ts'], bundle: true, format: 'esm', write: false });
const { marketSchedule, validSessionAlerts } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
const rule = { id: 'test', kind: 'move', symbol: 'ES=F', threshold: 0.5, direction: 'either' };
const now = Date.parse('2026-10-19T12:00:00Z');
const q = (price, at = now) => ({ 'ES=F': { price, previousClose: 100, at } });
test('weekends, holidays, early close and DST', () => {
  assert.equal(marketSchedule(Date.parse('2026-10-17T16:00:00Z')).next_open, '2026-10-19T13:30:00.000Z');
  assert.equal(marketSchedule(Date.parse('2026-11-26T16:00:00Z')).next_open, '2026-11-27T14:30:00.000Z');
  assert.equal(marketSchedule(Date.parse('2026-11-27T16:00:00Z')).close, '2026-11-27T18:00:00.000Z');
});
test('time alerts use bounded window and mark only successful delivery', () => {
  const schedule = marketSchedule(now), alert = { id: 'open', kind: 'preopen', minutes: 15 }, at = Date.parse('2026-10-19T13:15:00Z');
  assert.equal(sessionAlertEvents([alert], schedule, {}, {}, at - 1).length, 0);
  const event = sessionAlertEvents([alert], schedule, {}, {}, at)[0];
  assert.ok(event);
  assert.equal(sessionAlertEvents([alert], schedule, {}, {}, at).length, 1);
  assert.equal(sessionAlertEvents([alert], schedule, {}, { [event.key]: { at: new Date(at).toISOString() } }, at).length, 0);
  assert.equal(sessionAlertEvents([alert], schedule, {}, {}, at + 120000).length, 0);
  assert.equal(sessionAlertEvents([{ id: 'close', kind: 'close' }], marketSchedule(Date.parse('2026-11-27T16:00:00Z')), {}, {}, Date.parse('2026-11-27T18:05:00Z')).length, 1);
});
test('stale rejection, direction, crossing and cooldown', () => {
  for (const price of [100.5, 99.5]) assert.equal(sessionAlertEvents([rule], null, q(price), {}, now).length, 1);
  for (const quotes of [q(101, now - 300001), q(101, now + 60001), q(NaN)]) assert.equal(sessionAlertEvents([rule], null, quotes, {}, now).length, 0);
  const key = 'session:test:move', state = { [key]: { at: new Date(now).toISOString(), armed: false } };
  assert.equal(sessionAlertEvents([rule], null, q(101, now + 1800000), state, now + 1800000).length, 0);
  sessionAlertEvents([rule], null, q(100, now + 120000), state, now + 120000);
  assert.equal(state[key].armed, true);
  assert.equal(sessionAlertEvents([rule], null, q(101, now + 120000), state, now + 120000).length, 0);
  assert.equal(sessionAlertEvents([rule], null, q(101, now + 1800000), state, now + 1800000).length, 1);
  assert.equal(sessionAlertEvents([{ ...rule, direction: 'up' }], null, q(99), {}, now).length, 0);
});
test('validate rules, limits and duplicate IDs', () => {
  assert.equal(validSessionAlerts([rule]), true);
  for (const value of [null, [rule, rule], [{ ...rule, symbol: 'FAKE' }], [{ ...rule, threshold: NaN }], [{ ...rule, threshold: 0 }], [{ id: 'x', kind: 'preopen', minutes: 0 }]]) assert.equal(validSessionAlerts(value), false);
});
test('reopening waits for actual fresh quotes and suppresses maintenance/holiday false positives', () => {
  const reopen = Date.parse('2026-10-18T22:00:00Z'), alert = { id: 'r', kind: 'reopen' };
  assert.equal(sessionAlertEvents([alert], null, {}, {}, reopen).length, 0);
  assert.equal(sessionAlertEvents([alert], null, q(101, reopen - 1), {}, reopen).length, 0);
  const event = sessionAlertEvents([alert], null, q(101, reopen), {}, reopen)[0];
  assert.ok(event);
  assert.equal(sessionAlertEvents([alert], null, q(101, reopen), { [event.key]: { at: new Date(reopen).toISOString() } }, reopen).length, 0);
  assert.equal(sessionAlertEvents([alert], null, q(101, reopen + 900000), {}, reopen + 900000).length, 0);
  const friday = Date.parse('2026-10-16T22:00:00Z');
  assert.equal(sessionAlertEvents([alert], null, q(101, friday), {}, friday).length, 0);
  const winter = Date.parse('2026-11-01T23:00:00Z');
  assert.equal(sessionAlertEvents([alert], null, q(101, winter), {}, winter).length, 1);
});
test('one-time event alerts validate and trigger at the saved time', () => {
  const alert = { id: 'event', kind: 'event', title: 'CPI in 10 minutes', at: new Date(now).toISOString() };
  assert.equal(validSessionAlerts([alert]), true);
  assert.equal(sessionAlertEvents([alert], null, {}, {}, now - 1).length, 0);
  assert.equal(sessionAlertEvents([alert], null, {}, {}, now).length, 1);
  assert.equal(sessionAlertEvents([alert], null, {}, {}, now + 120000).length, 0);
});
