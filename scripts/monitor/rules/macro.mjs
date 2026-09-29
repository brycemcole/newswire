import { fredSeries } from '../fetch_series.mjs';
import { signed } from '../fetch.mjs';

export const id = 'macro';

const thousands = value => Math.round(value).toLocaleString('en-US');

async function inflation(events) {
  const points = await fredSeries('CPIAUCSL');
  const latest = points.at(-1);
  const yearAgo = points.at(-13);
  const priorMonth = points.at(-2);
  if (!latest || !yearAgo || !priorMonth) return;
  const annual = ((latest.value - yearAgo.value) / yearAgo.value) * 100;
  const monthly = ((latest.value - priorMonth.value) / priorMonth.value) * 100;
  const hot = annual >= 4 || annual <= 1;
  events.push({
    key: `macro:cpi:${latest.date}`,
    title: `US CPI inflation runs at ${annual.toFixed(1)}% year over year for ${latest.date.slice(0, 7)}`,
    summary: `The consumer price index published to FRED shows prices ${annual.toFixed(1)}% higher than a year earlier and ${signed(monthly, 2)}% versus the prior month, based on the ${latest.date} observation of series CPIAUCSL. Not seasonally reinterpreted here; figures are taken directly from the published index.`,
    source: 'Federal Reserve Bank of St. Louis (FRED)',
    url: 'https://fred.stlouisfed.org/series/CPIAUCSL',
    category: 'economy',
    priority: hot ? 'urgent' : 'normal',
    tickers: [],
    tags: ['deterministic', 'macro', 'inflation'],
  });
}

async function labor(events) {
  const [rate, payrolls] = await Promise.all([fredSeries('UNRATE'), fredSeries('PAYEMS')]);
  const latest = rate.at(-1);
  const prior = rate.at(-2);
  if (latest && prior) {
    const change = latest.value - prior.value;
    events.push({
      key: `macro:unrate:${latest.date}`,
      title: `US unemployment rate is ${latest.value.toFixed(1)}% for ${latest.date.slice(0, 7)}`,
      summary: `The unemployment rate published to FRED stands at ${latest.value.toFixed(1)}%, ${change === 0 ? 'unchanged from' : `${signed(change, 1)} points versus`} the prior month's ${prior.value.toFixed(1)}%. Series UNRATE, observation dated ${latest.date}.`,
      source: 'Federal Reserve Bank of St. Louis (FRED)',
      url: 'https://fred.stlouisfed.org/series/UNRATE',
      category: 'economy',
      priority: Math.abs(change) >= 0.3 ? 'urgent' : 'normal',
      tickers: [],
      tags: ['deterministic', 'macro', 'employment'],
    });
  }
  const jobsNow = payrolls.at(-1);
  const jobsPrior = payrolls.at(-2);
  if (jobsNow && jobsPrior) {
    const change = jobsNow.value - jobsPrior.value;
    events.push({
      key: `macro:payems:${jobsNow.date}`,
      title: `US payrolls ${change >= 0 ? 'add' : 'shed'} ${thousands(Math.abs(change))},000 jobs in ${jobsNow.date.slice(0, 7)}`,
      summary: `Total nonfarm payroll employment published to FRED changed by ${signed(change, 0)} thousand in the ${jobsNow.date} observation, to ${thousands(jobsNow.value)} thousand jobs. Series PAYEMS.`,
      source: 'Federal Reserve Bank of St. Louis (FRED)',
      url: 'https://fred.stlouisfed.org/series/PAYEMS',
      category: 'economy',
      priority: Math.abs(change) >= 250 || change < 0 ? 'urgent' : 'normal',
      tickers: [],
      tags: ['deterministic', 'macro', 'employment'],
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
    key: `macro:icsa:${latest.date}`,
    title: `Initial jobless claims ${change >= 0 ? 'rise' : 'fall'} to ${thousands(latest.value)} for the week ending ${latest.date}`,
    summary: `Seasonally adjusted initial unemployment claims published to FRED came in at ${thousands(latest.value)}, ${signed(change, 0)} from the prior week${extreme ? `, the ${latest.value >= Math.max(...year) ? 'highest' : 'lowest'} reading of the past year` : ''}. Series ICSA.`,
    source: 'Federal Reserve Bank of St. Louis (FRED)',
    url: 'https://fred.stlouisfed.org/series/ICSA',
    category: 'economy',
    priority: extreme ? 'urgent' : 'normal',
    tickers: [],
    tags: ['deterministic', 'macro', 'employment'],
  });
}

export async function run() {
  const events = [];
  const failures = [];
  const settled = await Promise.allSettled([inflation(events), labor(events), claims(events)]);
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`macro-${['cpi', 'labor', 'claims'][index]}: ${entry.reason?.message ?? entry.reason}`); });
  return { events, failures };
}
