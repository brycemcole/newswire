import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';

const bundle = async entry => import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: [entry], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const { calculatePulse, scoreMarket } = await bundle('src/market-pulse.ts');
const { inputsAt } = await bundle('src/market-inputs.ts');
const cutoff = '2026-10-12T15:00:00Z', t = Date.parse(cutoff);
const input = (id, change_day, change_hour = 0, status = 'live') => ({ id, label: id, symbol: id, unit: id === 'yield' ? 'bp' : 'pct', price: 1, price_at: cutoff, change_day, change_hour, status });
const calm = () => ['oil', 'yen', 'vix', 'yield', 'futures'].map(id => input(id, 0));
const withInput = (id, day, hour) => calm().map(i => i.id === id ? input(id, day, hour) : i);

test('an oil spike hurts the broad market and airlines but helps energy', () => {
  const spike = withInput('oil', 5, 2);
  const spy = scoreMarket(spike, 'SPY').points, xle = scoreMarket(spike, 'XLE').points, dal = scoreMarket(spike, 'DAL').points;
  assert.ok(spy < -4 && xle > 6 && dal < spy, JSON.stringify({ spy, xle, dal }));
  assert.equal(scoreMarket(calm(), 'SPY').points, 0);
});

test('a sudden one-hour move registers before the 24-hour change catches up', () => {
  assert.ok(scoreMarket(withInput('futures', 0, -0.6), 'SPY').points < -1.5);
});

test('a fast yen rally is a headwind; yen weakness adds nothing', () => {
  assert.ok(scoreMarket(withInput('yen', -1.5, -0.5), 'SPY').points < -2);
  assert.equal(scoreMarket(withInput('yen', 1.5, 0.5), 'SPY').points, 0);
});

test('stale or missing prices never stand in for current conditions', () => {
  const weekend = calm().map(i => ({ ...i, status: 'stale' }));
  assert.equal(scoreMarket(weekend, 'SPY').status, 'unavailable');
  const noNews = calculatePulse([], cutoff, 'SPY', false, { market: weekend });
  assert.equal(noNews.status, 'no_coverage');
  assert.equal(noNews.score, null);
  const live = calculatePulse([], cutoff, 'SPY', false, { market: withInput('vix', 20, 5) });
  assert.equal(live.status, 'available');
  assert.ok(live.score < 45);
  assert.equal(live.components.news.status, 'no_coverage');
});

test('news and prices add, and the total stays inside 0–100', () => {
  const story = { id: 'a', title: 'Missile attack hits Saudi oil facilities', summary: '', source: 'Reuters', url: 'https://example.com/a',
    published_at: '2026-10-12T14:00:00Z', received_at: '2026-10-12T14:01:00Z', retracted_at: null, tags: ['headlines'], tickers: [] };
  const newsOnly = calculatePulse([story], cutoff, 'SPY');
  const both = calculatePulse([story], cutoff, 'SPY', false, { market: withInput('oil', 6, 2) });
  assert.ok(both.score < newsOnly.score);
  assert.equal(both.score, Math.round((50 + both.components.news.points + both.components.market.points) * 100) / 100);
  const extreme = calculatePulse([story], cutoff, 'DAL', false, { market: ['oil', 'yen', 'vix', 'yield', 'futures'].map(id => input(id, id === 'yen' || id === 'futures' ? -50 : 50, id === 'yen' || id === 'futures' ? -50 : 50)) });
  assert.ok(extreme.score >= 0 && extreme.score <= 100);
});

test('replayed points use only bars closed by then; only the live point uses the live quote', () => {
  const times = [], closes = [];
  for (let m = 26 * 60; m >= 0; m -= 5) { times.push(t - m * 60000); closes.push(m <= 60 ? 110 : 100); }
  const bars = [{ symbol: 'CL=F', times, closes, live: { price: 120, time: t } }];
  const replay = inputsAt(bars, t).find(i => i.id === 'oil');
  assert.equal(replay.price, 110);
  assert.equal(replay.change_day, 10);
  assert.equal(replay.change_hour, 10);
  assert.equal(inputsAt(bars, t, true).find(i => i.id === 'oil').price, 120);
  assert.equal(inputsAt(bars, t + 4 * 3600000).find(i => i.id === 'oil').status, 'stale');
  assert.equal(inputsAt(bars, t).find(i => i.id === 'yen').status, 'unavailable');
});

test('a hot inflation print is a headwind and a release still ahead lowers confidence', () => {
  const cpi = { title: 'CPI m/m', at: '2026-10-12T12:30:00Z', forecast: '0.3%', actual: '0.6%', surprise: 0.3, threshold: 0.2 };
  const hot = calculatePulse([], cutoff, 'SPY', false, { market: calm(), calendar: [cpi] });
  assert.ok(hot.components.calendar.points < -3 && hot.score < 47);
  const jobsBeat = calculatePulse([], cutoff, 'SPY', false, { market: calm(), calendar: [{ ...cpi, title: 'Retail Sales m/m', surprise: 0.8, threshold: 0.5 }] });
  assert.ok(jobsBeat.components.calendar.points > 0);
  const ahead = calculatePulse([], cutoff, 'SPY', false, { market: withInput('oil', 1, 0), calendar: [{ ...cpi, at: '2026-10-12T18:00:00Z', actual: null, surprise: null }] });
  assert.equal(ahead.confidence, 'low');
  assert.deepEqual(ahead.components.calendar.upcoming.map(e => e.title), ['CPI m/m']);
  assert.equal(ahead.components.calendar.points, 0);
});

test("an overseas close stays current until the US session; a US quote does not", () => {
  const close = t - 7 * 3600000, times = [close - 25 * 3600000, close - 5 * 60000], closes = [100, 102];
  const inputs = inputsAt([{ symbol: '^N225', times, closes, live: null }, { symbol: 'CL=F', times, closes, live: null }], t);
  assert.equal(inputs.find(i => i.id === 'asia').status, 'live');
  assert.equal(inputs.find(i => i.id === 'asia').change_day, 2);
  assert.equal(inputs.find(i => i.id === 'oil').status, 'stale');
});

const impact = (id, extra = {}) => ({ id, title: 'Missile attack hits Saudi oil field', source: 'Reuters', url: `https://example.com/${id}`, published_at: '2026-10-12T14:00:00Z',
  received_at: '2026-10-12T14:01:00Z', classified_at: '2026-10-12T14:02:00Z', direction: -1, channel: 'energy', size: 'major', confidence: 0.9, ...extra });

test("Jev's headline reads move the news score, saturate on repeats and respect the cutoff", () => {
  const one = calculatePulse([], cutoff, 'SPY', false, { impacts: [impact('a')] });
  assert.equal(one.components.news.method, 'jev');
  assert.ok(one.components.news.points < -2 && one.score < 48);
  const twenty = calculatePulse([], cutoff, 'SPY', false, { impacts: Array.from({ length: 20 }, (_, i) => impact(`c${i}`)) });
  assert.ok(twenty.components.news.points >= -6.01);
  assert.ok(calculatePulse([], cutoff, 'XLE', false, { impacts: [impact('a')] }).components.news.points > 0);
  const later = calculatePulse([], cutoff, 'SPY', false, { impacts: [impact('a', { received_at: '2026-10-12T15:00:01Z' })] });
  assert.equal(later.score, null);
  const unclassified = calculatePulse([], cutoff, 'SPY', false, { impacts: [impact('missing-classification', { classified_at: undefined })] });
  assert.equal(unclassified.components.news.method, 'rules');
  assert.equal(unclassified.components.news.status, 'no_coverage');
});

test('the explanation leads with a plain call and the biggest driver', async () => {
  const { explain } = await bundle('src/pulse-text.ts');
  const p = calculatePulse([], cutoff, 'SPY', false, { market: withInput('oil', 6, 2), impacts: [impact('a')] });
  const text = explain(p);
  assert.match(text.call.headline, /lower/);
  assert.equal(text.call.tone, 'negative');
  assert.match(text.summary, /^(Oil is up 6\.0% since yesterday|Headlines about oil and energy supply)/);
  assert.ok(text.drivers.some(d => d.kind === 'news' && d.url === 'https://example.com/a'));
  assert.equal(text.drivers.find(d => d.kind === 'price').stat.label, 'WTI crude, per barrel');
  assert.equal(explain(calculatePulse([], cutoff, 'SPY', false, { market: calm() })).call.headline, 'No clear direction');
});
