import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const bundle = async entry => import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: [entry], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const { fedPath, meetingDates, blsEvents, chokepointRows, form4, ftsQuery, render, minorCurrency, actualFrom, measureFor, parseFigure } = await bundle('src/data.ts');
const { listing } = await bundle('src/quotes.ts');

test('FOMC calendar parsing keeps scheduled decision days only', () => {
  const html = `<h4>2026 FOMC Meetings</h4>
    <div class="fomc-meeting__month"><strong>October</strong></div><div class="fomc-meeting__date">27-28</div>
    <div class="fomc-meeting__month"><strong>Apr/May</strong></div><div class="fomc-meeting__date">30-1*</div>
    <div class="fomc-meeting__month"><strong>August</strong></div><div class="fomc-meeting__date">22 (notation vote)</div>
    <h4>2027 FOMC Meetings</h4><div class="fomc-meeting__month"><strong>January</strong></div><div class="fomc-meeting__date">26-27</div>`;
  assert.deepEqual(meetingDates(html), ['2026-05-01', '2026-10-28', '2027-01-27']);
});

test('fed funds futures imply the post-meeting rate', () => {
  // A meeting on the 15th of a 30-day month cutting from 4.00 to 3.75 averages 3.875 for the month.
  const averages = new Map([['2026-09', 3.875], ['2026-10', 3.75], ['2026-11', 3.75], ['2026-12', 3.5]]);
  const path = fedPath(4, ['2026-09-15', '2026-12-31'], averages);
  assert.equal(path[0].rate, 3.75);
  assert.equal(path[0].move, -25);
  assert.equal(path.length, 2);
  assert.equal(path[1].cumulative < -25, true);
});

test('BLS calendar, chokepoints, Form 4 and full-text helpers', () => {
  const ics = 'BEGIN:VEVENT\nDTSTART;TZID=US-Eastern:20261009T083000\nSUMMARY:Employment Situation\nEND:VEVENT\nBEGIN:VEVENT\nDTSTART;TZID=US-Eastern:20261014T140000\nSUMMARY:Consumer Price Index\nEND:VEVENT';
  assert.deepEqual(blsEvents(ics).map(r => [r.label, r.date, r.value]), [['Employment Situation', '2026-10-09', '8:30 AM ET'], ['Consumer Price Index', '2026-10-14', '2:00 PM ET']]);
  const records = Array.from({ length: 37 }, (_, i) => ({ date: `2026-09-${String(i % 30 + 1).padStart(2, '0')}`, portname: 'Strait of Hormuz', n_total: i >= 30 ? 6 : 10, n_tanker: 2 }));
  records.forEach((r, i) => { if (i >= 30) r.date = `2026-10-0${i - 29}`; });
  const [row] = chokepointRows(records);
  assert.equal(row.value, '6.0 ships/day');
  assert.equal(row.change, -40);
  const xml = '<rptOwnerName>DOE JANE</rptOwnerName><officerTitle>CFO</officerTitle><nonDerivativeTransaction><transactionCode>S</transactionCode><transactionShares><value>1000</value></transactionShares><transactionPricePerShare><value>50</value></transactionPricePerShare></nonDerivativeTransaction>';
  assert.deepEqual(form4(xml).map(r => [r.label, r.value]), [['DOE JANE (CFO)', 'Sale 1,000 sh']]);
  assert.equal(ftsQuery('Fed "rate" OR cuts!'), '"fed"* "rate"* "cuts"*');
  assert.equal(ftsQuery('a ?'), '');
  const text = render({ title: 'T', source: 'S', url: 'https://x', as_of: '2026-10-06T00:00:00Z', sections: [{ title: 'Rows', rows: [{ label: 'A', value: '1%', change: 2 }] }] });
  assert.match(text, /- A: 1% \(\+2\.00%\)/);
  assert.equal(minorCurrency('GBp'), 'GBP');
  assert.equal(minorCurrency('USD'), null);
});

test('exchange-prefixed tickers map to Yahoo listings', () => {
  assert.equal(listing('TYO', '7203'), '7203.T');
  assert.equal(listing('HKEX', '700'), '0700.HK');
  assert.equal(listing('LSE', 'SHEL'), 'SHEL.L');
  assert.equal(listing('NYSE', 'BRK.B'), 'BRK-B');
  assert.equal(listing('ETR', 'SAP'), 'SAP.DE');
  assert.equal(listing('CEO', 'X'), null);
});

test('US release actuals line up with the forecast for the right period', () => {
  const cpi = measureFor('USD', 'Core CPI m/m');
  const points = [{ date: '2026-07-01', value: 300 }, { date: '2026-08-01', value: 300.9 }, { date: '2026-09-01', value: 301.2 }];
  const result = actualFrom({ at: '2026-09-11T12:30:00.000Z', forecast: '0.2%' }, cpi, points);
  assert.equal(result.text, '0.3%');
  assert.equal(result.surprise, 0.1);
  assert.equal(result.big, false);
  const payrolls = measureFor('USD', 'Non-Farm Employment Change');
  const jobs = actualFrom({ at: '2026-10-02T12:30:00.000Z', forecast: '150K' }, payrolls, [{ date: '2026-08-01', value: 160000 }, { date: '2026-09-01', value: 159950 }]);
  assert.equal(jobs.text, '-50K');
  assert.equal(jobs.big, true);
  assert.equal(measureFor('CAD', 'Unemployment Rate'), undefined);
  assert.equal(parseFigure('7.10M'), 7.1);
  assert.equal(parseFigure('-41.7K'), -41.7);
  assert.equal(parseFigure(''), undefined);
});

test('release calculations reject missing periods and normalize forecast units', () => {
  const jobs = measureFor('USD', 'Non-Farm Employment Change');
  const event = { at: '2026-10-02T12:30:00Z', forecast: '0.15M' };
  const points = [{ date: '2026-08-01', value: 160000 }, { date: '2026-09-01', value: 160100 }];
  assert.equal(actualFrom(event, jobs, points).surprise, -50);
  assert.equal(actualFrom(event, jobs, [{ date: '2026-07-01', value: 160000 }, points[1]]), undefined);
  assert.equal(parseFigure('1.2.3%'), undefined);
  assert.equal(parseFigure('NaN'), undefined);
  assert.equal(parseFigure('−41K'), -41);
  assert.equal(measureFor('USD', 'CPI y/y').series, 'CPIAUCNS');
});

test('historical calendar retains duplicate unlabeled series without guessing frequency', async () => {
  const { historicalRows } = await import('../../scripts/monitor/calendar.mjs');
  const rows = historicalRows([
    { country: 'United States', eventName: 'CPI', actual: '0.4%', consensus: '0.3%', previous: '0.2%' },
    { country: 'United States', eventName: 'CPI', actual: '3.4%', consensus: '3.4%', previous: '3.3%' },
    { country: 'United States', eventName: 'Fed Speaks', actual: '&nbsp;', consensus: ' ', previous: '&nbsp;' },
  ]);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].forecast, '0.3%');
  assert.match(rows[1].detail, /series 2/);
  assert.equal(rows.some(row => /m\/m|y\/y/.test(row.label)), false);
});

test('public source search parses real RSS and ranks collected coverage', async () => {
  const { publicSourceRows } = await import('../../scripts/monitor/calendar.mjs');
  const rows = publicSourceRows('<rss><channel><item><title>Jobs beat &amp; inflation</title><link>https://news.google.com/rss/articles/example</link><pubDate>Tue, 06 Oct 2026 12:00:00 GMT</pubDate><source url="https://example.com">Publisher</source><description><![CDATA[<b>89K consensus</b>]]></description></item></channel></rss>');
  assert.equal(rows[0].label, 'Jobs beat & inflation');
  assert.equal(rows[0].detail, '89K consensus');
  const { runTool } = await bundle('src/data.ts');
  const env = { DB: { prepare: () => ({ first: async () => ({ payload: JSON.stringify(rows), updated_at: new Date().toISOString() }) }) } };
  const result = await runTool('source_search', { q: 'jobs consensus' }, env);
  assert.equal(result.sections[0].rows[0].value, 'Publisher');
  assert.match(result.text, /89K consensus/);
});

test('FRED falls back to a recent collector snapshot and labels its freshness', async () => {
  const { runTool } = await bundle('src/data.ts');
  const previous = globalThis.fetch;
  globalThis.fetch = async () => new Response('blocked', { status: 403 });
  const updated_at = new Date(Date.now() - 2 * 3600000).toISOString();
  const payload = JSON.stringify({ id: 'UNRATE', title: 'Unemployment', units: '%', observations: [{ date: '2026-08-01', value: 4.1 }, { date: '2026-09-01', value: 4.2 }] });
  const env = { DB: { prepare: () => ({ bind: () => ({ first: async () => ({ payload, updated_at }) }) }) } };
  try {
    const result = await runTool('series', { id: 'UNRATE' }, env);
    assert.equal(result.sections[0].rows[0].value, '4.200 %');
    assert.match(result.note, /collector snapshot.*upstream unavailable/);
    const expired = { DB: { prepare: () => ({ bind: () => ({ first: async () => ({ payload, updated_at: '2020-01-01T00:00:00Z' }) }) }) } };
    await assert.rejects(() => runTool('series', { id: 'UNRATE' }, expired), /FRED returned 403/);
  } finally { globalThis.fetch = previous; }
});

test('13F held-since walks back through consecutive quarter-end reports only', async () => {
  const { heldSince, consecutiveQuarters } = await bundle('src/data.ts');
  assert.equal(consecutiveQuarters('2026-06-30', '2026-09-30'), true);
  assert.equal(consecutiveQuarters('2025-12-31', '2026-03-31'), true);
  assert.equal(consecutiveQuarters('2026-03-31', '2026-09-30'), false);
  const snap = (period, ...cusips) => ({ period, cusips: new Set(cusips) });
  const snapshots = [snap('2026-09-30', 'A', 'B', 'C', 'D'), snap('2026-06-30', 'B', 'C', 'E'), snap('2026-03-31', 'C', 'E'), snap('2025-12-31', 'C', 'E')];
  // New this quarter: first reported at the current quarter end, and the prior report proves it was not held.
  assert.deepEqual(heldSince('A', snapshots), { held_since: '2026-09-30' });
  assert.deepEqual(heldSince('B', snapshots), { held_since: '2026-06-30' });
  // Present in every report checked, so only a lower bound.
  assert.deepEqual(heldSince('C', snapshots), { held_since: '2025-12-31', held_since_bound: true });
  // Exited positions start from the prior report.
  assert.deepEqual(heldSince('E', snapshots, 1), { held_since: '2025-12-31', held_since_bound: true });
  assert.deepEqual(heldSince('Z', snapshots), {});
  // A skipped quarter breaks the run: what came before the gap is unknown.
  const gapped = [snap('2026-09-30', 'C'), snap('2026-06-30', 'C'), snap('2025-12-31', 'C')];
  assert.deepEqual(heldSince('C', gapped), { held_since: '2026-06-30', held_since_bound: true });
  // With only one report, even a held position's start is a lower bound.
  assert.deepEqual(heldSince('C', [snap('2026-09-30', 'C')]), { held_since: '2026-09-30', held_since_bound: true });
});

test('13F holdings resolve to US tickers by CUSIP and by issuer name', async () => {
  const { figiTicker, listingFor } = await bundle('src/data.ts');
  assert.equal(figiTicker({ data: [{ ticker: 'BRK/B', exchCode: 'UN', marketSector: 'Equity' }, { ticker: 'BRK/B', exchCode: 'US', marketSector: 'Equity' }] }), 'BRK-B');
  assert.equal(figiTicker({ data: [{ ticker: 'ECHO 3.875 11/30/30', exchCode: 'TRACE', marketSector: 'Corp' }] }), null);
  assert.equal(figiTicker({ warning: 'No identifier found.' }), null);
  const quotes = [
    { symbol: 'BSP.VI', exchange: 'VIE', quoteType: 'EQUITY', longname: 'Bending Spoons S.p.A.' },
    { symbol: 'BSP', exchange: 'NMS', quoteType: 'EQUITY', longname: 'Bending Spoons S.p.A.' },
  ];
  assert.equal(listingFor('BENDING SPOONS SPA', quotes), 'BSP');
  // A different company sharing the first word is not accepted.
  assert.equal(listingFor('BENDING ROADS INC', quotes), null);
  assert.equal(listingFor('BENDING SPOONS SPA', quotes.slice(0, 1)), null);
});

test('13F basket performance chain-links daily closes at reported share counts', async () => {
  const { basketIndex, basketReturns } = await bundle('src/data.ts');
  const closes = entries => new Map(entries);
  // B lists on day 3; its arrival must not register as a gain.
  const points = basketIndex([
    { shares: 10, closes: closes([['2026-09-29', 10], ['2026-09-30', 11], ['2026-10-01', 11], ['2026-10-02', 12.1]]) },
    { shares: 100, closes: closes([['2026-10-01', 5], ['2026-10-02', 5]]) },
  ]);
  assert.deepEqual(points.map(p => p.x), ['2026-09-29', '2026-09-30', '2026-10-01', '2026-10-02']);
  assert.equal(points[1].value, 110);
  assert.equal(points[2].value, 110);
  // Day 4: A +10% on 110 of 610 basket value → +1.803%.
  assert.equal(points[3].value, 111.984);
  const returns = Object.fromEntries(basketReturns(points, '2026-09-30').map(r => [r.label, r]));
  assert.equal(returns['1D'].percent, 1.8);
  assert.equal(returns['Since report'].since, '2026-09-30');
  assert.equal(returns['Since report'].percent, 1.8);
  assert.equal(returns['1Y'], undefined);
  assert.equal(returns['1W'], undefined);
  assert.deepEqual(basketReturns(points.slice(0, 1), '2026-09-30'), []);
});
