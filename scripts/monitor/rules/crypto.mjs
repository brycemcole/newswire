import { getJson, money, quotes, signed } from '../fetch.mjs';

const coins = [
  { symbol: 'BTC-USD', name: 'Bitcoin', ticker: 'BTC', move: 5, round: 10000 },
  { symbol: 'ETH-USD', name: 'Ether', ticker: 'ETH', move: 7, round: 1000 },
];

export const id = 'crypto';

export async function run() {
  const { values, failures } = await quotes(coins.map(entry => entry.symbol), '1y');
  const events = [];
  for (const entry of coins) {
    const data = values.get(entry.symbol);
    if (!data) continue;
    if (Math.abs(data.changePercent) >= entry.move) {
      events.push({
        key: `crypto:${entry.ticker}:${data.session}:${data.changePercent >= 0 ? 'up' : 'down'}:${Math.trunc(Math.abs(data.changePercent) / entry.move)}`,
        title: `${entry.name} moves ${signed(data.changePercent, 1)}% in 24 hours to $${money(data.price)}`,
        summary: `${entry.name} trades at $${money(data.price)}, ${signed(data.changePercent, 1)}% from $${money(data.previousClose)} a day earlier. Levels from Yahoo Finance as of ${data.quotedAt}.`,
        source: 'Yahoo Finance',
        url: `https://finance.yahoo.com/quote/${entry.symbol}`,
        category: 'markets',
        priority: Math.abs(data.changePercent) >= entry.move * 2 ? 'urgent' : 'normal',
        tickers: [entry.ticker],
        tags: ['deterministic', 'crypto'],
      });
    }
    const crossed = Math.floor(data.price / entry.round) !== Math.floor(data.previousClose / entry.round);
    if (crossed) {
      const line = Math.floor(Math.max(data.price, data.previousClose) / entry.round) * entry.round;
      events.push({
        key: `crypto:${entry.ticker}:level:${line}:${data.price >= data.previousClose ? 'up' : 'down'}`,
        title: `${entry.name} ${data.price >= data.previousClose ? 'breaks above' : 'falls below'} $${money(line)}`,
        summary: `${entry.name} moved ${data.price >= data.previousClose ? 'through' : 'back under'} $${money(line)} and trades at $${money(data.price)}. Levels from Yahoo Finance as of ${data.quotedAt}.`,
        source: 'Yahoo Finance',
        url: `https://finance.yahoo.com/quote/${entry.symbol}`,
        category: 'markets',
        priority: 'normal',
        tickers: [entry.ticker],
        tags: ['deterministic', 'crypto', 'price-level'],
      });
    }
    if (data.price >= data.peakClose) {
      events.push({
        key: `crypto:${entry.ticker}:52w-high:${data.session}`,
        title: `${entry.name} hits a 52-week high at $${money(data.price)}`,
        summary: `${entry.name} traded at $${money(data.price)}, above its highest close of the past year at $${money(data.peakClose)}. Levels from Yahoo Finance as of ${data.quotedAt}.`,
        source: 'Yahoo Finance',
        url: `https://finance.yahoo.com/quote/${entry.symbol}`,
        category: 'markets',
        priority: 'urgent',
        tickers: [entry.ticker],
        tags: ['deterministic', 'crypto', '52-week-high'],
      });
    }
  }
  return { events, failures };
}
