import { fredSeries } from '../fetch_series.mjs';
import { signed } from '../fetch.mjs';

export const id = 'fed';

async function targetRate(events) {
  const [upper, lower] = await Promise.all([fredSeries('DFEDTARU'), fredSeries('DFEDTARL')]);
  const latest = upper.at(-1);
  if (!latest) return;
  const changed = [...upper].reverse().find(point => point.value !== latest.value);
  if (!changed || Date.parse(latest.date) - Date.parse(changed.date) > 10 * 86400000) return;
  const move = (latest.value - changed.value) * 100;
  const floor = lower.at(-1)?.value;
  events.push({
    key: `fed:target:${latest.date}:${latest.value}`,
    title: `Fed funds target range moves to ${floor !== undefined ? `${floor.toFixed(2)}-` : ''}${latest.value.toFixed(2)}%`,
    summary: `The federal funds target range upper limit published to FRED changed to ${latest.value.toFixed(2)}% effective ${latest.date}, ${signed(move, 0)} basis points from ${changed.value.toFixed(2)}% on ${changed.date}. Series DFEDTARU and DFEDTARL.`,
    source: 'Federal Reserve Bank of St. Louis (FRED)',
    url: 'https://fred.stlouisfed.org/series/DFEDTARU',
    category: 'economy',
    priority: 'breaking',
    tickers: [],
    tags: ['deterministic', 'monetary-policy', 'fed'],
  });
}

async function balanceSheet(events) {
  const points = await fredSeries('WALCL');
  const latest = points.at(-1);
  const monthAgo = points.at(-5);
  if (!latest || !monthAgo) return;
  const change = latest.value - monthAgo.value;
  if (Math.abs(change) < 100000) return;
  events.push({
    key: `fed:balance-sheet:${latest.date}`,
    title: `Fed balance sheet ${change >= 0 ? 'expands' : 'shrinks'} $${Math.abs(change / 1000).toFixed(0)} billion in four weeks`,
    summary: `Total Federal Reserve assets stand at $${(latest.value / 1e6).toFixed(3)} trillion as of ${latest.date}, a change of ${signed(change / 1000, 0)} billion dollars from $${(monthAgo.value / 1e6).toFixed(3)} trillion on ${monthAgo.date}. Series WALCL.`,
    source: 'Federal Reserve Bank of St. Louis (FRED)',
    url: 'https://fred.stlouisfed.org/series/WALCL',
    category: 'economy',
    priority: 'normal',
    tickers: [],
    tags: ['deterministic', 'monetary-policy', 'fed'],
  });
}

export async function run() {
  const events = [];
  const failures = [];
  const tasks = [targetRate, balanceSheet];
  const settled = await Promise.allSettled(tasks.map(task => task(events)));
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`fed-${tasks[index].name}: ${entry.reason?.message ?? entry.reason}`); });
  return { events, failures };
}
