import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, rm } from 'node:fs/promises';
import { day, marketSession, money, signed } from '../../scripts/monitor/fetch.mjs';

const statePath = new URL('./monitor-state.tmp.json', import.meta.url).pathname;
process.env.NEWSWIRE_MONITOR_STATE = statePath;
const { load, save } = await import('../../scripts/monitor/state.mjs');

test('signed and money format for headlines', () => {
  assert.equal(signed(1.234, 2), '+1.23');
  assert.equal(signed(-1.235, 1), '-1.2');
  assert.equal(money(7718.6), '7,719');
  assert.equal(money(14.53), '14.53');
});

test('market session buckets follow New York hours', () => {
  const at = iso => marketSession(Date.parse(iso));
  assert.equal(at('2026-09-04T14:30:00Z'), 'open');
  assert.equal(at('2026-09-04T11:00:00Z'), 'premarket');
  assert.equal(at('2026-09-04T21:00:00Z'), 'afterhours');
  assert.equal(at('2026-09-04T03:00:00Z'), 'closed');
  assert.equal(at('2026-09-05T14:30:00Z'), 'closed');
  assert.equal(at('2026-09-08T14:30:00Z'), 'open');
});

test('day resolves the exchange-local session date', () => {
  assert.equal(day(Date.parse('2026-09-04T23:30:00Z'), 'America/New_York'), '2026-09-04');
  assert.equal(day(Date.parse('2026-09-04T23:30:00Z'), 'UTC'), '2026-09-04');
  assert.equal(day(Date.parse('2026-09-05T02:30:00Z'), 'America/New_York'), '2026-09-04');
});

test('state round-trips and drops entries older than three weeks', async () => {
  const recent = new Date().toISOString();
  const stale = new Date(Date.now() - 22 * 86400000).toISOString();
  await save({ keep: { at: recent, rule: 'markets' }, drop: { at: stale, rule: 'markets' } });
  const loaded = await load();
  assert.deepEqual(Object.keys(loaded), ['keep']);
  const mode = (await readFile(statePath, 'utf8')).length > 0;
  assert.ok(mode);
  await rm(statePath, { force: true });
});

test('missing state file loads as empty', async () => {
  await rm(statePath, { force: true });
  assert.deepEqual(await load(), {});
});

test('digest summarize counts only fresh published events and skips digests', async () => {
  const { summarize } = await import('../../scripts/monitor/rules/digest.mjs');
  const now = Date.parse('2026-09-07T14:30:00Z');
  const entries = {
    fresh: { at: '2026-09-07T13:00:00Z', rule: 'markets' },
    older: { at: '2026-09-06T20:00:00Z', rule: 'fiscal' },
    stale: { at: '2026-09-05T09:00:00Z', rule: 'markets' },
    yesterdayDigest: { at: '2026-09-06T14:00:00Z', rule: 'digest' },
    future: { at: '2026-09-07T23:00:00Z', rule: 'rates' },
    corrupt: { at: 'not-a-date', rule: 'markets' },
  };
  assert.deepEqual(summarize(entries, now), { total: 2, counts: [['fiscal', 1], ['markets', 1]], latest: 'markets' });
  assert.deepEqual(summarize({}, now), { total: 0, counts: [], latest: null });
});

test('House filing dates parse in either day-first or month-first order', async () => {
  const source = await readFile(new URL('../../scripts/monitor/rules/congress.mjs', import.meta.url), 'utf8');
  const body = /function parseFilingDate\(value\) \{([\s\S]*?)\n\}/.exec(source)[1];
  const parseFilingDate = new Function('value', body);
  assert.equal(new Date(parseFilingDate('8/21/2026')).toISOString().slice(0, 10), '2026-08-21');
  assert.equal(new Date(parseFilingDate('21/8/2026')).toISOString().slice(0, 10), '2026-08-21');
  assert.equal(new Date(parseFilingDate('7/6/2026')).toISOString().slice(0, 10), '2026-07-06');
  assert.ok(Number.isNaN(parseFilingDate('not-a-date')));
});

test('Form 4 transaction totals sum by code and price', async () => {
  const source = await readFile(new URL('../../scripts/monitor/rules/insiders.mjs', import.meta.url), 'utf8');
  const helpers = /function field[\s\S]*?\n\}\n\nfunction role/.exec(source)[0].replace(/\nfunction role$/, '');
  const totalsFn = /function transactions\(xml\) \{[\s\S]*?\n\}/.exec(source)[0];
  const codes = "const codes = { P: { notable: true }, S: { notable: true }, A: { notable: false } };";
  const build = shares => `<nonDerivativeTransaction><transactionCoding><transactionCode>S</transactionCode></transactionCoding><transactionAmounts><transactionShares><value>${shares}</value></transactionShares><transactionPricePerShare><value>10</value></transactionPricePerShare></transactionAmounts></nonDerivativeTransaction>`;
  const run = new Function(`${codes}\n${helpers}\n${totalsFn}\nreturn transactions;`)();
  const totals = run(build(100) + build(50) + '<nonDerivativeHolding><transactionShares><value>999</value></transactionShares></nonDerivativeHolding>');
  assert.equal(totals.get('S').shares, 150);
  assert.equal(totals.get('S').value, 1500);
  assert.equal(totals.size, 1);
});

test('shipping flags chokepoint transit shifts against the prior 30 days', async () => {
  const { shifts } = await import('../../scripts/monitor/rules/shipping.mjs');
  const records = Array.from({ length: 37 }, (_, i) => ({ date: new Date(Date.UTC(2026, 8, 1 + i)).toISOString().slice(0, 10), portname: 'Strait of Hormuz', n_total: i >= 30 ? 20 : 40, n_tanker: 10 }));
  const [event] = shifts([...records, ...records.map(r => ({ ...r, portname: 'Kerch Strait' }))]);
  assert.equal(event.title, 'Strait of Hormuz transits down 50% from their 30-day average');
  assert.equal(event.priority, 'urgent');
  assert.equal(shifts(records.map(r => ({ ...r, n_total: 40 }))).length, 0);
});

test('global flags overseas index and currency moves once per session bucket', async () => {
  const { indexEvents, currencyEvents } = await import('../../scripts/monitor/rules/global.mjs');
  const now = Date.parse('2026-10-06T07:00:00Z');
  const data = { price: 2400, previousClose: 2465, changePercent: -2.64, peakClose: 2700, troughClose: 2300, session: '2026-10-06', quotedAt: '2026-10-06T06:30:00Z' };
  const [event] = indexEvents({ symbol: '^KS11', name: 'KOSPI', place: 'Seoul', ticker: 'KOSPI' }, data, now);
  assert.equal(event.title, 'KOSPI drops 2.64% in Seoul trading');
  assert.equal(event.priority, 'urgent');
  assert.equal(event.key, 'global:^KS11:2026-10-06:down:2');
  assert.equal(indexEvents({ symbol: '^KS11', name: 'KOSPI', place: 'Seoul', ticker: 'KOSPI' }, { ...data, changePercent: 0.8 }, now).length, 0);
  assert.equal(indexEvents({ symbol: '^KS11', name: 'KOSPI', place: 'Seoul', ticker: 'KOSPI' }, data, now + 2 * 86400000).length, 0);
  const [fx] = currencyEvents({ symbol: 'JPY=X', name: 'Dollar-yen', ticker: 'USDJPY', move: 1, digits: 2 }, { ...data, price: 160.2, previousClose: 158, changePercent: 1.39 }, now);
  assert.equal(fx.title, 'Dollar strengthens 1.39% against the JPY to 160.20');
});
