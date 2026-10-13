import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { priceComparison } from '../../scripts/market-pulse/prices.mjs';

const { calculatePulse, pulseTime } = await import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: ['src/market-pulse.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const cutoff = '2026-10-12T11:00:00Z';
const story = (extra = {}) => ({ id: 'one', title: 'Missile attack hits Saudi oil facilities', summary: '', source: 'Publisher', url: 'https://example.com/one',
  published_at: '2026-10-12T10:00:00Z', received_at: '2026-10-12T10:01:00Z', retracted_at: null, tags: ['headlines'], tickers: [], ...extra });

test('receipt time, publication time and retractions enforce the information cutoff', () => {
  const base = calculatePulse([story()], cutoff);
  const later = story({ id: 'two', title: 'China imposes new tariffs', received_at: '2026-10-12T11:00:01Z' });
  assert.deepEqual(calculatePulse([story(), later], cutoff), base);
  assert.deepEqual(calculatePulse([story(), story({ id: 'future', published_at: '2026-10-12T11:00:01Z' })], cutoff), base);
  assert.equal(calculatePulse([story({ received_at: '' })], cutoff).score, null);
  assert.deepEqual(calculatePulse([story({ retracted_at: '2026-10-12T12:00:00Z' })], cutoff), base);
  assert.equal(calculatePulse([story({ retracted_at: cutoff })], cutoff).coverage.eligible_stories, 0);
  assert.equal(calculatePulse([story({ received_at: cutoff })], cutoff).coverage.eligible_stories, 1);
});

test('syndication and later repetitions do not amplify or refresh the same event', () => {
  const base = calculatePulse([story()], cutoff);
  const repeated = Array.from({ length: 30 }, (_, i) => story({ id: `copy-${i}`, source: `Outlet ${i}`, published_at: '2026-10-12T10:30:00Z', received_at: '2026-10-12T10:31:00Z' }));
  const p = calculatePulse([story(), ...repeated], cutoff);
  assert.equal(p.score, base.score);
  assert.equal(p.coverage.event_groups, 1);
  assert.deepEqual(calculatePulse([...repeated].reverse().concat(story()), cutoff), p);
});

test('supply disruption has opposite exposure for energy and airlines', () => {
  const spy = calculatePulse([story()], cutoff, 'SPY');
  assert.ok(spy.score < 50);
  assert.ok(calculatePulse([story()], cutoff, 'XLE').score > 50);
  assert.ok(calculatePulse([story()], cutoff, 'DAL').score < spy.score);
  assert.throws(() => calculatePulse([story()], cutoff, 'NOT-SUPPORTED'), /Supported/);
});

test('stale or empty coverage cannot masquerade as a usable neutral score', () => {
  const old = story({ published_at: '2026-10-09T10:00:00Z', received_at: '2026-10-09T10:01:00Z' });
  const p = calculatePulse([old], cutoff);
  assert.equal(p.status, 'stale');
  assert.equal(p.score, null);
  assert.ok(p.research_score < 50);
  assert.equal(calculatePulse([], cutoff).status, 'no_coverage');
  assert.equal(calculatePulse([story({ title: 'New AI model launched' })], cutoff).status, 'no_signal');
  assert.equal(calculatePulse([story()], cutoff, 'SPY', true).status, 'incomplete');
});

test('replayed late backfills do not refresh coverage or event age', () => {
  const old = story({ published_at: '2026-10-09T10:00:00Z' });
  assert.equal(calculatePulse([old], cutoff).status, 'stale');
  assert.equal(calculatePulse([story({ published_at: '2026-10-01T10:00:00Z' })], cutoff).coverage.eligible_stories, 0);
});

test('rumors, negation, hypotheticals and price recaps are not causal event evidence', () => {
  for (const title of ['Saudi denies missile attack on oil facilities', 'Saudi says no attack hit oil facilities', 'Could a Saudi missile attack disrupt oil?', 'If Saudi attacks oil facilities, stocks could fall', 'Oil prices rise 5%', 'US stocks slide as oil prices surge', 'Saudi oil facilities attacked last year']) {
    assert.equal(calculatePulse([story({ title })], cutoff).score, null, title);
  }
});

test('a local energy problem without a recognized broad-market supply channel is unclassified', () => {
  for (const title of ['Cuba forges ahead with renewable energy plans amid US oil blockade', 'Town closes energy pipeline after minor outage', 'Local refinery shuts for maintenance']) {
    assert.equal(calculatePulse([story({ title })], cutoff).score, null, title);
  }
  assert.ok(calculatePulse([story({ title: 'Houthi missile attack targets Saudi capital Riyadh' })], cutoff).score < 50);
});

test('opposing new evidence offsets rather than erases risk and remains linked', () => {
  const before = calculatePulse([story()], cutoff);
  const after = calculatePulse([story(), story({ id: 'relief', title: 'Saudi restores oil production', published_at: '2026-10-12T10:45:00Z', received_at: '2026-10-12T10:46:00Z' })], cutoff);
  assert.ok(after.score > before.score);
  assert.equal(after.factors[0].conflicting, true);
  assert.equal(after.factors[0].evidence.length, 2);
});

test('newly arriving independent events change the score; factors remain bounded', () => {
  const later = story({ id: 'trade', title: 'China imposes new tariffs', published_at: '2026-10-12T11:01:00Z', received_at: '2026-10-12T11:02:00Z' });
  const a = calculatePulse([story(), later], cutoff);
  const b = calculatePulse([story(), later], '2026-10-12T11:03:00Z');
  assert.ok(b.score < a.score);
  assert.ok(b.score >= 0 && b.score <= 100);
  assert.equal(b.confidence, 'medium');
});

test('as-of requires a valid calendar date and explicit timezone, including DST offsets', () => {
  for (const bad of ['2026-10-12', '2026-10-12T07:00:00', '2026-02-30T07:00:00Z', '2026-10-12T24:00:00Z', 'bad']) assert.throws(() => pulseTime(bad));
  assert.equal(pulseTime('2026-10-12T07:00:00-04:00'), Date.parse(cutoff));
  assert.equal(pulseTime('2026-11-02T07:00:00-05:00'), Date.parse('2026-11-02T12:00:00Z'));
});

function chart(rows) {
  return { retrieved_at: '2026-10-12T21:00:00Z', payload: { chart: { result: [{ timestamp: rows.map(r => Date.parse(r[0]) / 1000),
    meta: { regularMarketPrice: 999999 }, indicators: { quote: [{ open: rows.map(r => r[1]), close: rows.map(r => r[2]), low: rows.map(r => r[3]) }] } }] } } };
}

test('cutoff uses completed bars, never a current quote or the 7 a.m. bar close', () => {
  const p = priceComparison(chart([
    ['2026-10-09T19:55:00Z', 100, 100, 100],
    ['2026-10-12T10:55:00Z', 99, 99, 99],
    ['2026-10-12T11:00:00Z', 98, 80, 79],
    ['2026-10-12T13:30:00Z', 95, 96, 94],
    ['2026-10-12T19:55:00Z', 92, 90, 89],
    ['2026-10-12T20:00:00Z', 90, 200, 80],
  ]), cutoff);
  assert.equal(p.at_cutoff.price, 99);
  assert.equal(p.pre_cutoff_change_pct, -1);
  assert.equal(p.regular_close, 90);
  assert.equal(p.cutoff_to_close_pct, -9.0909);
  assert.equal(p.open_to_close_pct, -5.2632);
  assert.equal(p.worst_after_cutoff_pct, -20.202);
});

test('missing, stale and incomplete prices stay unavailable', () => {
  assert.equal(priceComparison(null, cutoff).status, 'unavailable');
  assert.equal(priceComparison(chart([['2026-10-12T09:00:00Z', 100, 100, 100]]), cutoff).at_cutoff, null);
  const incomplete = chart([['2026-10-12T10:55:00Z', 100, 100, 100], ['2026-10-12T19:55:00Z', 99, 99, 99]]);
  incomplete.retrieved_at = '2026-10-12T19:57:00Z';
  assert.equal(priceComparison(incomplete, cutoff).regular_close, null);
});
