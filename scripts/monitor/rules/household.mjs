import { fredSeries } from '../fetch_series.mjs';
import { signed } from '../fetch.mjs';

export const id = 'household';

async function mortgages(events) {
  const points = await fredSeries('MORTGAGE30US');
  const latest = points.at(-1);
  const prior = points.at(-2);
  if (!latest || !prior) return;
  const change = latest.value - prior.value;
  const year = points.slice(-52).map(point => point.value);
  const extreme = latest.value >= Math.max(...year) ? 'highest' : latest.value <= Math.min(...year) ? 'lowest' : null;
  const crossed = [8, 7, 6, 5].find(line => (latest.value >= line) !== (prior.value >= line));
  if (Math.abs(change) < 0.1 && !extreme && !crossed) return;
  events.push({
    key: `household:mortgage:${latest.date}`,
    title: `30-year mortgage rate ${change >= 0 ? 'rises' : 'falls'} to ${latest.value.toFixed(2)}%`,
    summary: `Freddie Mac\u2019s average 30-year fixed mortgage rate published to FRED is ${latest.value.toFixed(2)}% for the week of ${latest.date}, ${signed(change, 2)} points from ${prior.value.toFixed(2)}%${extreme ? `, the ${extreme} reading of the past year` : ''}${crossed ? `, crossing ${crossed}%` : ''}. Series MORTGAGE30US.`,
    source: 'Federal Reserve Bank of St. Louis (FRED)',
    url: 'https://fred.stlouisfed.org/series/MORTGAGE30US',
    category: 'economy',
    priority: extreme || crossed ? 'urgent' : 'normal',
    tickers: [],
    tags: ['deterministic', 'housing', 'rates'],
  });
}

async function gasoline(events) {
  const points = await fredSeries('GASREGW');
  const latest = points.at(-1);
  const prior = points.at(-2);
  if (!latest || !prior) return;
  const change = ((latest.value - prior.value) / prior.value) * 100;
  const year = points.slice(-52).map(point => point.value);
  const extreme = latest.value >= Math.max(...year) ? 'highest' : latest.value <= Math.min(...year) ? 'lowest' : null;
  if (Math.abs(change) < 3 && !extreme) return;
  events.push({
    key: `household:gas:${latest.date}`,
    title: `US average gasoline price ${change >= 0 ? 'rises' : 'falls'} to $${latest.value.toFixed(2)} a gallon`,
    summary: `The national average regular gasoline price published to FRED is $${latest.value.toFixed(2)} for the week of ${latest.date}, ${signed(change, 1)}% from $${prior.value.toFixed(2)}${extreme ? `, the ${extreme} weekly price of the past year` : ''}. Series GASREGW, sourced from the EIA.`,
    source: 'Federal Reserve Bank of St. Louis (FRED)',
    url: 'https://fred.stlouisfed.org/series/GASREGW',
    category: 'economy',
    priority: extreme ? 'urgent' : 'normal',
    tickers: [],
    tags: ['deterministic', 'energy', 'consumer'],
  });
}

export async function run() {
  const events = [];
  const failures = [];
  const tasks = [mortgages, gasoline];
  const settled = await Promise.allSettled(tasks.map(task => task(events)));
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`household-${tasks[index].name}: ${entry.reason?.message ?? entry.reason}`); });
  return { events, failures };
}
