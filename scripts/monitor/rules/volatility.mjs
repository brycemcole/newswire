import { quotes, signed } from '../fetch.mjs';

const levels = [
  { at: 40, priority: 'breaking', note: 'crisis-era territory' },
  { at: 30, priority: 'breaking', note: 'acute stress territory' },
  { at: 20, priority: 'urgent', note: 'its long-run average' },
];

export const id = 'volatility';

export async function run() {
  const { values, failures } = await quotes(['^VIX']);
  const events = [];
  const vix = values.get('^VIX');
  if (!vix) return { events, failures };

  const level = levels.find(entry => vix.price >= entry.at);
  if (level) {
    events.push({
      key: `volatility:vix:${level.at}:${vix.session}`,
      title: `VIX trades above ${level.at} at ${vix.price.toFixed(2)}`,
      summary: `The Cboe Volatility Index is at ${vix.price.toFixed(2)}, ${signed(vix.changePercent, 1)}% from the prior close and above ${level.at}, ${level.note}. Levels from Yahoo Finance as of ${vix.quotedAt}.`,
      source: 'Yahoo Finance',
      url: 'https://finance.yahoo.com/quote/%5EVIX',
      category: 'markets',
      priority: level.priority,
      tickers: ['VIX'],
      tags: ['deterministic', 'volatility'],
    });
  }
  if (Math.abs(vix.changePercent) >= 20) {
    events.push({
      key: `volatility:vix-move:${vix.session}:${vix.changePercent >= 0 ? 'up' : 'down'}`,
      title: `VIX ${vix.changePercent >= 0 ? 'spikes' : 'collapses'} ${Math.abs(vix.changePercent).toFixed(1)}% in a session`,
      summary: `The Cboe Volatility Index moved ${signed(vix.changePercent, 1)}% to ${vix.price.toFixed(2)} from a prior close of ${vix.previousClose.toFixed(2)}. Levels from Yahoo Finance as of ${vix.quotedAt}.`,
      source: 'Yahoo Finance',
      url: 'https://finance.yahoo.com/quote/%5EVIX',
      category: 'markets',
      priority: 'urgent',
      tickers: ['VIX'],
      tags: ['deterministic', 'volatility'],
    });
  }
  return { events, failures };
}
