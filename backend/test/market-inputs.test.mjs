import assert from 'node:assert/strict';
import test from 'node:test';
import { build } from 'esbuild';

const bundle = async entry => import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: [entry], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const { calculatePulse, scoreMarket } = await bundle('src/market-pulse.ts');
const { inputsAt, lastCashClose } = await bundle('src/market-inputs.ts');
const { marketInstruments } = await bundle('src/market-pulse.ts');
const hourMs = 3600000, barMs = 300000;
// Prices are 50 everywhere except the bars ending at the marked instants (100) and at t (110).
const barsFor = (symbol, t, marks) => {
  const times = [], closes = [];
  for (let end = t - 7 * 24 * hourMs; end <= t; end += barMs) { times.push(end - barMs); closes.push(marks[end] ?? 50); }
  return { symbol, times, closes, live: null };
};
const dayChange = (id, symbol, t, baselineEnd) => inputsAt([barsFor(symbol, t, { [baselineEnd]: 100, [t]: 110 })], t).find(i => i.id === id).change_day;
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

test('yen moves have symmetric effects around neutral', () => {
  assert.ok(scoreMarket(withInput('yen', -1.5, -0.5), 'SPY').points < -2);
  assert.equal(scoreMarket(withInput('yen', 1.5, 0.5), 'SPY').points, -scoreMarket(withInput('yen', -1.5, -0.5), 'SPY').points);
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

test('all formerly asymmetric inputs cancel for equal opposite moves across profiles', () => {
  for (const symbol of ['SPY', 'QQQ', 'XLE', 'DAL']) for (const id of ['yen', 'vix', 'yield', 'credit', 'dollar']) {
    const base = ['yen', 'vix', 'yield', 'credit', 'dollar'].map(key => input(key, 0));
    const points = sign => scoreMarket(base.map(i => i.id === id ? input(id, sign * 0.5, sign * 0.2) : i), symbol).points;
    assert.equal(points(1) + points(-1), 0, `${symbol} ${id}`);
  }
});

test('index futures compare with the last 4 PM New York close; other markets keep 24 hours', () => {
  const sundayEvening = Date.parse('2026-10-19T00:00:00Z'), fridayClose = Date.parse('2026-10-16T20:00:00Z');
  assert.equal(lastCashClose(sundayEvening), fridayClose);
  assert.equal(dayChange('futures', 'ES=F', sundayEvening, fridayClose), 10);
  const wednesdayEvening = Date.parse('2026-10-15T00:00:00Z'), wednesdayClose = Date.parse('2026-10-14T20:00:00Z');
  assert.equal(lastCashClose(wednesdayEvening), wednesdayClose);
  assert.equal(dayChange('nasdaq', 'NQ=F', wednesdayEvening, wednesdayClose), 10);
  const wednesdayMorning = Date.parse('2026-10-14T15:00:00Z'), tuesdayClose = Date.parse('2026-10-13T20:00:00Z');
  assert.equal(lastCashClose(wednesdayMorning), tuesdayClose);
  assert.equal(dayChange('smallcaps', 'RTY=F', wednesdayMorning, tuesdayClose), 10);
  const mondayWinter = Date.parse('2026-01-12T17:00:00Z'), fridayWinterClose = Date.parse('2026-01-09T21:00:00Z');
  assert.equal(lastCashClose(mondayWinter), fridayWinterClose);
  assert.equal(dayChange('oil', 'CL=F', wednesdayMorning, wednesdayMorning - 24 * hourMs), 10);
});

test('the yield input is Treasury note futures, where a rising price is good for stocks', () => {
  const spec = marketInstruments.find(i => i.id === 'yield');
  assert.equal(spec.symbol, 'ZN=F');
  assert.equal(spec.unit, 'pct');
  assert.equal(spec.baseline, undefined);
});

test('VIX term structure: backwardation is a headwind, a calm curve a tailwind', () => {
  const level = (id, price) => ({ id, label: id, symbol: id, unit: 'ratio', price, price_at: cutoff, change_day: null, change_hour: null, status: 'live' });
  const pointsFor = price => scoreMarket([level('vix_term', price)], 'SPY').inputs.find(i => i.id === 'vix_term').points;
  assert.ok(pointsFor(1.05) < 0, String(pointsFor(1.05)));
  assert.ok(pointsFor(0.85) > 0, String(pointsFor(0.85)));
});

test('a 3-session S&P drop adds mild support, and the drawdown counts against the SPY exposure', () => {
  const drop = { id: 'drawdown', label: 'drawdown', symbol: 'SPY', unit: 'pct', price: 500, price_at: cutoff, change_day: -4, change_hour: null, status: 'live' };
  const row = scoreMarket([drop], 'SPY').inputs.find(i => i.id === 'drawdown');
  assert.ok(row.points > 0 && row.points < 4, String(row.points));
  assert.ok(scoreMarket([drop], 'XLE').inputs.find(i => i.id === 'drawdown').points < row.points);
});

test('a drawdown on a Sunday night compares with the prior Tuesday 4 PM New York close', () => {
  const sundayEvening = Date.parse('2026-10-19T00:00:00Z'), tuesdayClose = Date.parse('2026-10-13T20:00:00Z'), mondayClose = Date.parse('2026-10-12T20:00:00Z');
  assert.equal(lastCashClose(sundayEvening), Date.parse('2026-10-16T20:00:00Z'));
  const row = inputsAt([barsFor('SPY', sundayEvening, { [tuesdayClose]: 100, [mondayClose]: 90, [sundayEvening]: 96 })], sundayEvening).find(i => i.id === 'drawdown');
  assert.equal(row.change_day, -4);
  assert.equal(row.status, 'live');
});

test('VIX term and drawdown appear in the inputs and count toward live inputs', () => {
  const rows = inputsAt([barsFor('^VIX', t, {}), barsFor('^VIX3M', t, { [t]: 60 }), barsFor('SPY', t, {})], t);
  const ratio = rows.find(i => i.id === 'vix_term'), drawdown = rows.find(i => i.id === 'drawdown');
  assert.equal(ratio.price, 0.833);
  assert.equal(ratio.status, 'live');
  assert.equal(drawdown.status, 'live');
  assert.equal(scoreMarket(rows, 'SPY').live_inputs, 3);
});

// Bellwether bars: price 100 before the 4 PM close, the given price for every bar after it.
const premarketBars = (prices, t) => {
  const cash = lastCashClose(t);
  return Object.entries(prices).map(([symbol, price]) => {
    const times = [], closes = [];
    for (let end = t - 7 * 24 * hourMs; end <= t; end += barMs) { times.push(end - barMs); closes.push(end - barMs >= cash ? price : 100); }
    return { symbol, times, closes, live: null };
  });
};
const premarket = (t, prices) => inputsAt(premarketBars(prices, t), t).find(i => i.id === 'premarket');
const mondaySevenAm = Date.parse('2026-10-12T11:00:00Z'), mondayEightPm = Date.parse('2026-10-13T00:00:00Z'), mondayElevenAm = Date.parse('2026-10-12T15:00:00Z');
const allUp = { NVDA: 101, MSFT: 101, AAPL: 101, AMZN: 101, XOM: 101, CVX: 101 };

test('pre-market basket is live at 07:00 ET with six fresh bellwethers and scores their weighted move', () => {
  const row = premarket(mondaySevenAm, allUp);
  assert.equal(row.status, 'live');
  assert.equal(row.members.length, 6);
  const scored = scoreMarket([row], 'SPY').inputs.find(i => i.id === 'premarket');
  assert.equal(scored.change_day, 1);
  assert.equal(scored.points, 4.57);
  assert.ok(scored.points > 0);
});

test('pre-market basket is stale at 20:00 ET and at 11:00 ET even with fresh bellwethers', () => {
  assert.equal(premarket(mondayEightPm, allUp).status, 'stale');
  assert.equal(premarket(mondayElevenAm, allUp).status, 'stale');
  assert.equal(scoreMarket([premarket(mondayElevenAm, allUp)], 'SPY').inputs.find(i => i.id === 'premarket').points, 0);
});

test('pre-market basket needs at least five fresh bellwethers', () => {
  assert.equal(premarket(mondaySevenAm, { NVDA: 101, MSFT: 101, AAPL: 101, AMZN: 101 }).status, 'stale');
});

test('pre-market basket weights differ by profile: QQQ follows NVDA, XLE follows XOM', () => {
  const row = premarket(mondaySevenAm, { NVDA: 102, MSFT: 101, AAPL: 101, AMZN: 101, XOM: 97, CVX: 100 });
  const scored = scoreMarket([row], 'SPY');
  assert.equal(scored.inputs.find(i => i.id === 'premarket').change_day, 0.93);
  const qqq = scoreMarket([row], 'QQQ').inputs.find(i => i.id === 'premarket');
  const xle = scoreMarket([row], 'XLE').inputs.find(i => i.id === 'premarket');
  assert.equal(qqq.change_day, 1.22);
  assert.equal(xle.change_day, -0.97);
  assert.ok(qqq.points > 0 && xle.points < 0, JSON.stringify({ qqq: qqq.points, xle: xle.points }));
  assert.equal(qqq.points, 5.04);
});

const { makeFeatures, forecastTilt } = await bundle('src/forecast-model.ts');
const bar5 = (times, closes, live = null) => ({ times, closes, live });
const oilAt = (bars, at, live = null, liveMode = false) => inputsAt([{ symbol: 'CL=F', ...bars, live }], at, liveMode).find(i => i.id === 'oil');

test('missing baselines are not live, do not score, and do not look neutral to the forecast', () => {
  const at = Date.parse('2026-10-19T15:00:00Z');
  const noBaseline = ['ES=F', 'CL=F', 'JPY=X'].map(symbol => ({ symbol, times: [at - 5 * 60000], closes: [100], live: null }));
  const inputs = inputsAt(noBaseline, at);
  assert.ok(inputs.filter(i => ['futures', 'oil', 'yen'].includes(i.id)).every(i => i.status === 'unavailable' && i.change_day === null && i.price === 100));
  const market = scoreMarket(inputs, 'SPY');
  assert.equal(market.live_inputs, 0);
  assert.equal(market.status, 'unavailable');
  assert.equal(market.points, 0);
  const pulse = calculatePulse([], new Date(at).toISOString(), 'SPY', false, { market: inputs });
  assert.equal(pulse.status, 'no_coverage');
  assert.equal(pulse.score, null);
  assert.equal(forecastTilt(makeFeatures({ pulse })).tilt, 'unavailable');
});

test('a real zero counts as live coverage while a missing baseline does not', () => {
  const at = Date.parse('2026-10-19T15:00:00Z'), friday = Date.parse('2026-10-16T20:00:00Z');
  const flat = (symbol, baseAt) => ({ symbol, times: [baseAt - 5 * 60000, at - 5 * 60000], closes: [100, 100], live: null });
  const mixed = [
    { symbol: 'ES=F', times: [friday - 5 * 60000, at - 5 * 60000], closes: [100, 101], live: null },
    flat('JPY=X', at - 24 * 3600000), flat('^VIX', at - 24 * 3600000),
    { symbol: 'CL=F', times: [at - 5 * 60000], closes: [100], live: null },
  ];
  const inputs = inputsAt(mixed, at);
  assert.equal(inputs.find(i => i.id === 'futures').change_day, 1);
  assert.equal(inputs.find(i => i.id === 'yen').change_day, 0);
  assert.equal(inputs.find(i => i.id === 'yen').status, 'live');
  assert.equal(inputs.find(i => i.id === 'oil').status, 'unavailable');
  const market = scoreMarket(inputs, 'SPY');
  assert.equal(market.live_inputs, 3);
  assert.equal(market.status, 'available');
  assert.equal(market.points, scoreMarket(inputs.filter(i => i.id !== 'oil'), 'SPY').points);
  const pulse = calculatePulse([], new Date(at).toISOString(), 'SPY', false, { market: inputs });
  assert.equal(pulse.status, 'available');
  assert.equal(pulse.score, 50 + market.points);
});

test('a stale quote with a baseline keeps its price for inspection but is not live', () => {
  const at = Date.parse('2026-10-19T15:00:00Z');
  const row = oilAt({ times: [at - 24 * 3600000 - 5 * 60000, at - 4 * 3600000 - 5 * 60000], closes: [90, 110] }, at);
  assert.equal(row.status, 'stale');
  assert.equal(row.price, 110);
  assert.equal(row.change_day, 22.22);
});

test('a Labor Day weekday is not a pre-market session and the cash baseline skips the holiday', () => {
  const laborDayAt = Date.parse('2026-09-07T12:00:00Z'), tuesdayAt = Date.parse('2026-09-08T12:00:00Z'), fridayClose = Date.parse('2026-09-04T20:00:00Z');
  assert.equal(lastCashClose(tuesdayAt), fridayClose);
  assert.equal(premarket(laborDayAt, allUp).status, 'stale');
  assert.equal(premarket(tuesdayAt, allUp).status, 'live');
});

test('Thanksgiving and the early close use the real session close', () => {
  assert.equal(lastCashClose(Date.parse('2026-11-27T19:00:00Z')), Date.parse('2026-11-27T18:00:00Z'));
  assert.equal(lastCashClose(Date.parse('2026-11-26T12:00:00Z')), Date.parse('2026-11-25T21:00:00Z'));
});

test('a drawdown across a holiday counts sessions, not weekdays', () => {
  const tuesdayAt = Date.parse('2026-09-08T12:00:00Z');
  const marks = { [Date.parse('2026-09-01T20:00:00Z')]: 100, [Date.parse('2026-09-04T20:00:00Z')]: 96, [tuesdayAt]: 96 };
  const row = inputsAt([barsFor('SPY', tuesdayAt, marks)], tuesdayAt).find(i => i.id === 'drawdown');
  assert.equal(row.change_day, -4);
  assert.equal(row.status, 'live');
});

test('the newest valid observation wins: a newer closed bar beats older live metadata', () => {
  const at = Date.parse('2026-10-19T15:00:00Z');
  const bars = bar5([at - 24 * 3600000 - 5 * 60000, at - 5 * 60000], [90, 110]);
  const stale = oilAt(bars, at, { price: 100, time: at - 4 * 3600000 }, true);
  assert.equal(stale.price, 110);
  assert.equal(stale.price_at, new Date(at).toISOString());
  assert.equal(stale.status, 'live');
});

test('newer live metadata beats an older closed bar only when the snapshot is live', () => {
  const at = Date.parse('2026-10-19T15:00:00Z');
  const bars = bar5([at - 24 * 3600000 - 5 * 60000, at - 10 * 60000], [90, 110]);
  const live = { price: 120, time: at - 60000 };
  assert.equal(oilAt(bars, at, live, true).price, 120);
  assert.equal(oilAt(bars, at, live, false).price, 110);
});

test('future quotes and in-progress bars never leak into a replay', () => {
  const at = Date.parse('2026-10-19T15:00:00Z');
  const bars = bar5([at - 24 * 3600000 - 5 * 60000, at - 5 * 60000, at - 2 * 60000], [90, 110, 130]);
  assert.equal(oilAt(bars, at, { price: 140, time: at + 10 * 60000 }, true).price, 110);
  assert.equal(oilAt(bars, at, { price: 140, time: at + 10 * 60000 }, false).price, 110);
  assert.equal(oilAt(bars, at, null, false).price, 110);
});
