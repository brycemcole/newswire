import { marketSession, money, quotes, signed } from '../fetch.mjs';

export const id = 'sectors';

const sectors = [
  { symbol: 'XLK', name: 'Technology' },
  { symbol: 'XLC', name: 'Communication Services' },
  { symbol: 'XLY', name: 'Consumer Discretionary' },
  { symbol: 'XLP', name: 'Consumer Staples' },
  { symbol: 'XLE', name: 'Energy' },
  { symbol: 'XLF', name: 'Financials' },
  { symbol: 'XLV', name: 'Health Care' },
  { symbol: 'XLI', name: 'Industrials' },
  { symbol: 'XLB', name: 'Materials' },
  { symbol: 'XLRE', name: 'Real Estate' },
  { symbol: 'XLU', name: 'Utilities' },
];

export async function run() {
  const session = marketSession();
  if (session === 'closed') return { events: [], failures: [] };
  const { values, failures } = await quotes(sectors.map(entry => entry.symbol));
  const events = [];
  for (const entry of sectors) {
    const data = values.get(entry.symbol);
    if (!data || Math.abs(data.changePercent) < 2) continue;
    const direction = data.changePercent >= 0 ? 'up' : 'down';
    events.push({
      key: `sectors:${entry.symbol}:${data.session}:${direction}:${Math.trunc(Math.abs(data.changePercent) / 2)}`,
      title: `${entry.name} sector ${direction} ${Math.abs(data.changePercent).toFixed(1)}%`,
      summary: `The ${entry.name} Select Sector SPDR (${entry.symbol}) trades at $${money(data.price)}, ${signed(data.changePercent, 1)}% from a prior close of $${money(data.previousClose)}. Levels from Yahoo Finance as of ${data.quotedAt}; this alert reports the price move only and does not identify a cause.`,
      source: 'Yahoo Finance',
      url: `https://finance.yahoo.com/quote/${entry.symbol}`,
      category: 'markets',
      priority: Math.abs(data.changePercent) >= 4 ? 'urgent' : 'normal',
      tickers: [entry.symbol],
      tags: ['deterministic', 'equities', 'sector'],
    });
  }
  return { events, failures };
}
