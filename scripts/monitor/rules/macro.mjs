import { fredSeries } from '../fetch_series.mjs';
import { signed } from '../fetch.mjs';
import { token } from '../publish.mjs';
import { syncCalendar } from '../calendar.mjs';

export const id = 'macro';

const thousands = value => Math.round(value).toLocaleString('en-US');
const month = date => new Date(`${date}T12:00:00Z`).toLocaleDateString('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const quarter = date => `Q${Math.floor(Number(date.slice(5, 7)) / 3) + 1} ${date.slice(0, 4)}`;
const yoy = (points, index = points.length - 1) => {
  const now = points[index], before = points[index - 12];
  return now && before ? ((now.value - before.value) / before.value) * 100 : undefined;
};
const mom = (points, index = points.length - 1) => {
  const now = points[index], before = points[index - 1];
  return now && before ? ((now.value - before.value) / before.value) * 100 : undefined;
};
const fred = id => `https://fred.stlouisfed.org/series/${id}`;
const base = { source: 'Federal Reserve Bank of St. Louis (FRED)', category: 'economy', tickers: [] };
const thresholds = { CPIAUCSL: 0.2, CPILFESL: 0.2, PAYEMS: 75, UNRATE: 0.2, CES0500000003: 0.2, PCEPILFE: 0.2, PPIFIS: 0.3, RSAFS: 0.5, JTSJOL: 0.4, ICSA: 20, A191RL1Q225SBEA: 0.7 };

/** Consensus forecasts with FRED-computed actuals, from the Worker's `releases` tool. Missing forecasts never block a story. */
async function consensus() {
  try {
    const url = new URL('/v1/data/tool/releases?days=10&impact=all&countries=USD', process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev');
    const response = await fetch(url, { headers: { Authorization: `Bearer ${await token()}` }, signal: AbortSignal.timeout(20000) });
    if (!response.ok) return [];
    return (await response.json()).sections?.[0]?.rows ?? [];
  } catch {
    return [];
  }
}

export function expectation(rows, series, pattern) {
  const row = rows.find(r => r.series === series && r.forecast && r.actual && pattern.test(r.label));
  if (!row) return null;
  const big = typeof row.surprise === 'number' && Math.abs(row.surprise) >= (thresholds[series] ?? Infinity);
  const direction = row.surprise > 0 ? 'above' : row.surprise < 0 ? 'below' : 'in line with';
  return { forecast: row.forecast, actual: row.actual, big, title: `, vs ${row.forecast} expected`, sentence: ` Economists expected ${row.forecast} (${row.label.replace(/^USD /, '')}); the ${row.actual} reading came in ${direction} the forecast.` };
}
let rows = [];

async function inflation(events) {
  const [headline, core] = await Promise.all([fredSeries('CPIAUCSL'), fredSeries('CPILFESL')]);
  const latest = headline.at(-1);
  const annual = yoy(headline), monthly = mom(headline), prior = yoy(headline, headline.length - 2);
  if (!latest || annual === undefined || monthly === undefined) return;
  const coreLatest = core.at(-1)?.date === latest.date ? { annual: yoy(core), monthly: mom(core) } : null;
  const shift = prior === undefined ? 0 : annual - prior;
  const expected = expectation(rows, 'CPIAUCSL', /\bCPI m\/m$/) ?? expectation(rows, 'CPIAUCSL', /CPI y\/y$/);
  events.push({
    ...base,
    key: `macro:cpi:${latest.date}`,
    title: `US CPI ${monthly >= 0 ? 'rises' : 'falls'} ${Math.abs(monthly).toFixed(1)}% in ${month(latest.date)}, ${annual.toFixed(1)}% from a year ago${coreLatest?.annual !== undefined ? `; core ${coreLatest.annual.toFixed(1)}%` : ''}${expected?.title ?? ''}`,
    summary: `Consumer prices ${monthly >= 0 ? 'rose' : 'fell'} ${Math.abs(monthly).toFixed(2)}% from the prior month and stand ${annual.toFixed(1)}% above a year earlier${prior === undefined ? '' : `, ${shift === 0 ? 'unchanged from' : `${shift > 0 ? 'up' : 'down'} from`} ${prior.toFixed(1)}% the month before`}.${coreLatest?.annual !== undefined ? ` Core CPI, which excludes food and energy, is up ${coreLatest.annual.toFixed(1)}% over the year and ${signed(coreLatest.monthly, 2)}% on the month.` : ''} ${expected?.sentence ?? ''} Computed from the published index levels (CPIAUCSL, CPILFESL).`,
    url: fred('CPIAUCSL'),
    priority: Math.abs(shift) >= 0.3 || annual >= 4 || expected?.big ? 'breaking' : 'urgent',
    tags: ['deterministic', 'macro', 'inflation', 'cpi'],
  });
}

async function labor(events) {
  const [rate, payrolls, wages] = await Promise.all([fredSeries('UNRATE'), fredSeries('PAYEMS'), fredSeries('CES0500000003')]);
  const latest = rate.at(-1), prior = rate.at(-2);
  // The payrolls story carries the rate; a separate story only when the rate itself moves.
  if (latest && prior && Math.abs(latest.value - prior.value) >= 0.2) {
    const change = latest.value - prior.value;
    events.push({
      ...base,
      key: `macro:unrate:${latest.date}`,
      title: `US unemployment rate ${change === 0 ? 'holds at' : change > 0 ? 'rises to' : 'falls to'} ${latest.value.toFixed(1)}% in ${month(latest.date)}`,
      summary: `The unemployment rate stands at ${latest.value.toFixed(1)}%, ${change === 0 ? 'unchanged from' : `${signed(change, 1)} points versus`} the prior month's ${prior.value.toFixed(1)}%. Series UNRATE, observation dated ${latest.date}.`,
      url: fred('UNRATE'),
      priority: Math.abs(change) >= 0.3 ? 'breaking' : 'normal',
      tags: ['deterministic', 'macro', 'employment', 'jobs-report'],
    });
  }
  const jobsNow = payrolls.at(-1), jobsPrior = payrolls.at(-2);
  if (jobsNow && jobsPrior) {
    const change = jobsNow.value - jobsPrior.value;
    const revisedPrior = payrolls.at(-3) ? jobsPrior.value - payrolls.at(-3).value : undefined;
    const pay = wages.at(-1)?.date === jobsNow.date ? yoy(wages) : undefined;
    const unemployment = latest?.date === jobsNow.date ? `, unemployment ${latest.value.toFixed(1)}%` : '';
    const expected = expectation(rows, 'PAYEMS', /Non-Farm Employment Change$/);
    events.push({
      ...base,
      key: `macro:payems:${jobsNow.date}`,
      title: `US payrolls ${change >= 0 ? 'add' : 'shed'} ${thousands(Math.abs(change))},000 jobs in ${month(jobsNow.date)}${expected?.title ?? ''}${unemployment}`,
      summary: `Nonfarm payrolls changed by ${signed(change, 0)} thousand to ${thousands(jobsNow.value)} thousand jobs${revisedPrior === undefined ? '' : `, after ${signed(revisedPrior, 0)} thousand the month before as now published`}.${latest?.date === jobsNow.date ? ` The unemployment rate is ${latest.value.toFixed(1)}%.` : ''}${pay === undefined ? '' : ` Average hourly earnings are up ${pay.toFixed(1)}% from a year earlier.`} ${expected?.sentence ?? ''} Series PAYEMS, UNRATE and CES0500000003.`,
      url: fred('PAYEMS'),
      priority: Math.abs(change) >= 250 || change < 0 || expected?.big ? 'breaking' : 'urgent',
      tags: ['deterministic', 'macro', 'employment', 'jobs-report'],
    });
  }
}

async function claims(events) {
  const points = await fredSeries('ICSA');
  const latest = points.at(-1);
  const prior = points.at(-2);
  if (!latest || !prior) return;
  const change = latest.value - prior.value;
  const year = points.slice(-52).map(point => point.value);
  const extreme = latest.value >= Math.max(...year) || latest.value <= Math.min(...year);
  if (Math.abs(change) < 25000 && !extreme) return;
  events.push({
    ...base,
    key: `macro:icsa:${latest.date}`,
    title: `Initial jobless claims ${change >= 0 ? 'rise' : 'fall'} to ${thousands(latest.value)} for the week ending ${latest.date}`,
    summary: `Seasonally adjusted initial unemployment claims published to FRED came in at ${thousands(latest.value)}, ${signed(change, 0)} from the prior week${extreme ? `, the ${latest.value >= Math.max(...year) ? 'highest' : 'lowest'} reading of the past year` : ''}. Series ICSA.`,
    url: fred('ICSA'),
    priority: extreme ? 'urgent' : 'normal',
    tags: ['deterministic', 'macro', 'employment'],
  });
}

async function pce(events) {
  const [headline, core] = await Promise.all([fredSeries('PCEPI'), fredSeries('PCEPILFE')]);
  const latest = core.at(-1);
  const annual = yoy(core), monthly = mom(core), overall = headline.at(-1)?.date === latest?.date ? yoy(headline) : undefined;
  if (!latest || annual === undefined || monthly === undefined) return;
  events.push({
    ...base,
    key: `macro:pce:${latest.date}`,
    title: `Core PCE prices, the Fed's preferred gauge, up ${annual.toFixed(1)}% from a year ago in ${month(latest.date)}`,
    summary: `The core personal consumption expenditures price index rose ${signed(monthly, 2)}% on the month and ${annual.toFixed(1)}% over the year${overall === undefined ? '' : `; the headline index including food and energy is up ${overall.toFixed(1)}%`}. Computed from index levels (PCEPILFE, PCEPI).`,
    url: fred('PCEPILFE'),
    priority: 'urgent',
    tags: ['deterministic', 'macro', 'inflation', 'pce'],
  });
}

async function producer(events) {
  const points = await fredSeries('PPIFIS');
  const latest = points.at(-1);
  const annual = yoy(points), monthly = mom(points);
  if (!latest || annual === undefined || monthly === undefined) return;
  events.push({
    ...base,
    key: `macro:ppi:${latest.date}`,
    title: `US producer prices ${monthly >= 0 ? 'rise' : 'fall'} ${Math.abs(monthly).toFixed(1)}% in ${month(latest.date)}, ${annual.toFixed(1)}% from a year ago`,
    summary: `The producer price index for final demand changed ${signed(monthly, 2)}% from the prior month and ${signed(annual, 1)}% from a year earlier. Series PPIFIS.`,
    url: fred('PPIFIS'),
    priority: Math.abs(monthly) >= 0.5 ? 'urgent' : 'normal',
    tags: ['deterministic', 'macro', 'inflation', 'ppi'],
  });
}

async function growth(events) {
  const points = await fredSeries('A191RL1Q225SBEA');
  const latest = points.at(-1), prior = points.at(-2);
  if (!latest) return;
  events.push({
    ...base,
    key: `macro:gdp:${latest.date}:${latest.value}`,
    title: `US economy ${latest.value >= 0 ? 'grows' : 'shrinks'} at ${Math.abs(latest.value).toFixed(1)}% annual rate in ${quarter(latest.date)}`,
    summary: `Real GDP changed at a seasonally adjusted annual rate of ${latest.value.toFixed(1)}% in ${quarter(latest.date)}${prior ? `, after ${prior.value.toFixed(1)}% the quarter before` : ''}. BEA estimates are revised twice after the advance release; this story reflects the figure as published to FRED. Series A191RL1Q225SBEA.`,
    url: fred('A191RL1Q225SBEA'),
    priority: latest.value < 0 ? 'breaking' : 'urgent',
    tags: ['deterministic', 'macro', 'gdp', 'growth'],
  });
}

async function spending(events) {
  const points = await fredSeries('RSAFS');
  const latest = points.at(-1);
  const monthly = mom(points), annual = yoy(points);
  if (!latest || monthly === undefined) return;
  events.push({
    ...base,
    key: `macro:retail:${latest.date}`,
    title: `US retail sales ${monthly >= 0 ? 'rise' : 'fall'} ${Math.abs(monthly).toFixed(1)}% in ${month(latest.date)}`,
    summary: `Advance retail and food services sales changed ${signed(monthly, 2)}% from the prior month to $${(latest.value / 1000).toFixed(1)} billion${annual === undefined ? '' : `, ${signed(annual, 1)}% from a year earlier`}. Figures are nominal and not adjusted for inflation. Series RSAFS.`,
    url: fred('RSAFS'),
    priority: Math.abs(monthly) >= 1 ? 'urgent' : 'normal',
    tags: ['deterministic', 'macro', 'consumer', 'retail-sales'],
  });
}

async function openings(events) {
  const points = await fredSeries('JTSJOL');
  const latest = points.at(-1), prior = points.at(-2);
  if (!latest || !prior) return;
  const change = latest.value - prior.value;
  events.push({
    ...base,
    key: `macro:jolts:${latest.date}`,
    title: `US job openings ${change >= 0 ? 'rise' : 'fall'} to ${(latest.value / 1000).toFixed(2)} million in ${month(latest.date)}`,
    summary: `Job openings in the JOLTS survey ${change >= 0 ? 'rose' : 'fell'} by ${thousands(Math.abs(change))},000 to ${thousands(latest.value)},000. Series JTSJOL.`,
    url: fred('JTSJOL'),
    priority: Math.abs(change) >= 500 ? 'urgent' : 'normal',
    tags: ['deterministic', 'macro', 'employment', 'jolts'],
  });
}

const parts = { cpi: inflation, labor, claims, pce, ppi: producer, gdp: growth, retail: spending, jolts: openings };

const annotations = {
  'macro:pce:': ['PCEPILFE', /Core PCE Price Index m\/m$/],
  'macro:ppi:': ['PPIFIS', /\bPPI m\/m$/],
  'macro:retail:': ['RSAFS', /\bRetail Sales m\/m$/],
  'macro:jolts:': ['JTSJOL', /JOLTS Job Openings$/],
  'macro:icsa:': ['ICSA', /Unemployment Claims$/],
  'macro:gdp:': ['A191RL1Q225SBEA', /GDP q\/q$/],
  'macro:unrate:': ['UNRATE', /Unemployment Rate$/],
};

export function annotate(event, list) {
  const entry = Object.entries(annotations).find(([prefix]) => event.key.startsWith(prefix));
  const expected = entry && expectation(list, ...entry[1]);
  if (!expected) return event;
  const rank = { normal: 0, urgent: 1, breaking: 2 };
  const priority = expected.big ? (rank[event.priority] < 1 ? 'urgent' : 'breaking') : event.priority;
  return { ...event, title: event.title + expected.title, summary: event.summary + expected.sentence, priority };
}

export async function run() {
  const failures = await syncCalendar().catch(error => [`calendar: ${error.message}`]);
  rows = await consensus();
  const events = [];
  const names = Object.keys(parts);
  const settled = await Promise.allSettled(names.map(name => parts[name](events)));
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`macro-${names[index]}: ${entry.reason?.message ?? entry.reason}`); });
  return { events: events.map(event => annotate(event, rows)), failures };
}
