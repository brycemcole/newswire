import { marketSession, money, quotes } from '../fetch.mjs';

const indices = [
  { symbol: '^GSPC', name: 'S&P 500', ticker: 'SPX' },
  { symbol: '^IXIC', name: 'Nasdaq Composite', ticker: 'IXIC' },
  { symbol: '^DJI', name: 'Dow Jones Industrial Average', ticker: 'DJI' },
  { symbol: '^RUT', name: 'Russell 2000', ticker: 'RUT' },
];
const futures = [
  { symbol: 'ES=F', name: 'S&P 500 futures', ticker: 'ES' },
  { symbol: 'NQ=F', name: 'Nasdaq 100 futures', ticker: 'NQ' },
];
const ladder = [
  { move: 3, priority: 'breaking', label: 'sharp' },
  { move: 2, priority: 'urgent', label: 'steep' },
  { move: 1, priority: 'normal', label: 'notable' },
];

function chartUrl(symbol) {
  return `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}`;
}

export const id = 'markets';

export async function run() {
  const session = marketSession();
  const live = session === 'open' || session === 'afterhours';
  const watch = live ? indices : futures;
  const { values, failures } = await quotes([...watch.map(entry => entry.symbol), '^GSPC']);
  const events = [];

  for (const entry of watch) {
    const data = values.get(entry.symbol);
    if (!data) continue;
    const hit = ladder.find(step => Math.abs(data.changePercent) >= step.move);
    if (!hit) continue;
    const direction = data.changePercent >= 0 ? 'up' : 'down';
    const magnitude = Math.abs(data.changePercent).toFixed(2);
    const window = session === 'open' ? 'intraday' : session === 'afterhours' ? 'at the close' : 'overnight';
    events.push({
      key: `markets:${entry.symbol}:${data.session}:${direction}:${Math.trunc(Math.abs(data.changePercent))}`,
      title: `${entry.name} ${direction} ${magnitude}% ${window}`,
      summary: `${entry.name} is ${direction} ${magnitude}% at ${money(data.price)} against a prior close of ${money(data.previousClose)}, a ${hit.label} ${direction === 'up' ? 'advance' : 'decline'}. Levels from Yahoo Finance as of ${data.quotedAt}.`,
      source: 'Yahoo Finance',
      url: chartUrl(entry.symbol),
      category: 'markets',
      priority: hit.priority,
      tickers: [entry.ticker],
      tags: ['deterministic', 'equities', session],
    });
  }

  const spx = values.get('^GSPC');
  if (spx) {
    if (spx.price >= spx.peakClose && spx.changePercent > 0) {
      events.push({
        key: `markets:^GSPC:record:${spx.session}`,
        title: `S&P 500 sets a new 52-week high at ${money(spx.price)}`,
        summary: `The S&P 500 reached ${money(spx.price)}, above its highest close of the past year at ${money(spx.peakClose)}. Levels from Yahoo Finance as of ${spx.quotedAt}.`,
        source: 'Yahoo Finance',
        url: chartUrl('^GSPC'),
        category: 'markets',
        priority: 'urgent',
        tickers: ['SPX'],
        tags: ['deterministic', 'equities', '52-week-high'],
      });
    }
    const drawdown = ((spx.price - spx.peakClose) / spx.peakClose) * 100;
    const threshold = [20, 10].find(level => drawdown <= -level);
    if (threshold) {
      events.push({
        key: `markets:^GSPC:drawdown${threshold}`,
        title: `S&P 500 is ${Math.abs(drawdown).toFixed(1)}% below its 52-week peak`,
        summary: `At ${money(spx.price)} the S&P 500 sits ${Math.abs(drawdown).toFixed(1)}% under its highest close of the past year at ${money(spx.peakClose)}, past the ${threshold}% ${threshold === 20 ? 'bear-market' : 'correction'} marker. Levels from Yahoo Finance as of ${spx.quotedAt}.`,
        source: 'Yahoo Finance',
        url: chartUrl('^GSPC'),
        category: 'markets',
        priority: threshold === 20 ? 'breaking' : 'urgent',
        tickers: ['SPX'],
        tags: ['deterministic', 'equities', 'drawdown'],
      });
    }
  }

  return { events, failures };
}
