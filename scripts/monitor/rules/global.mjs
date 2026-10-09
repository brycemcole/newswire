import { money, quotes } from '../fetch.mjs';

export const id = 'global';

const indices = [
  { symbol: '^KS11', name: 'KOSPI', place: 'Seoul', ticker: 'KOSPI' },
  { symbol: '^N225', name: 'Nikkei 225', place: 'Tokyo', ticker: 'NKY' },
  { symbol: '^HSI', name: 'Hang Seng', place: 'Hong Kong', ticker: 'HSI' },
  { symbol: '000001.SS', name: 'Shanghai Composite', place: 'Shanghai', ticker: 'SHCOMP' },
  { symbol: '^TWII', name: 'Taiwan Weighted', place: 'Taipei', ticker: 'TWII' },
  { symbol: '^AXJO', name: 'S&P/ASX 200', place: 'Sydney', ticker: 'ASX' },
  { symbol: '^NSEI', name: 'Nifty 50', place: 'Mumbai', ticker: 'NIFTY' },
  { symbol: '^GDAXI', name: 'DAX', place: 'Frankfurt', ticker: 'DAX' },
  { symbol: '^FTSE', name: 'FTSE 100', place: 'London', ticker: 'FTSE' },
  { symbol: '^FCHI', name: 'CAC 40', place: 'Paris', ticker: 'CAC' },
  { symbol: '^STOXX50E', name: 'Euro Stoxx 50', place: 'Europe', ticker: 'SX5E' },
];
const currencies = [
  { symbol: 'JPY=X', name: 'Dollar-yen', ticker: 'USDJPY', move: 1, digits: 2 },
  { symbol: 'KRW=X', name: 'Dollar-won', ticker: 'USDKRW', move: 1, digits: 1 },
  { symbol: 'EURUSD=X', name: 'Euro', ticker: 'EURUSD', move: 1, digits: 4 },
  { symbol: 'CNY=X', name: 'Dollar-yuan', ticker: 'USDCNY', move: 0.5, digits: 4 },
  { symbol: 'GBPUSD=X', name: 'Sterling', ticker: 'GBPUSD', move: 1, digits: 4 },
];
const ladder = [
  { move: 4, priority: 'breaking', label: 'sharp' },
  { move: 2.5, priority: 'urgent', label: 'steep' },
  { move: 1.5, priority: 'normal', label: 'notable' },
];
const url = symbol => `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}`;

export function indexEvents(entry, data, now = Date.now()) {
  if (now - Date.parse(data.quotedAt) > 20 * 3600000) return [];
  const hit = ladder.find(step => Math.abs(data.changePercent) >= step.move);
  if (!hit) return [];
  const direction = data.changePercent >= 0 ? 'up' : 'down';
  const magnitude = Math.abs(data.changePercent).toFixed(2);
  const record = data.price >= data.peakClose && direction === 'up' ? ', a 52-week high' : data.price <= data.troughClose && direction === 'down' ? ', a 52-week low' : '';
  return [{
    key: `global:${entry.symbol}:${data.session}:${direction}:${Math.trunc(Math.abs(data.changePercent))}`,
    title: `${entry.name} ${direction === 'up' ? 'jumps' : 'drops'} ${magnitude}% in ${entry.place} trading${record}`,
    summary: `The ${entry.name} is ${direction} ${magnitude}% at ${money(data.price)} against a prior close of ${money(data.previousClose)}, a ${hit.label} move for the ${data.session} session${record}. Levels from Yahoo Finance as of ${data.quotedAt}.`,
    source: 'Yahoo Finance',
    url: url(entry.symbol),
    published_at: data.quotedAt,
    category: 'markets',
    priority: hit.priority,
    tickers: [entry.ticker],
    tags: ['deterministic', 'equities', 'global', entry.place.toLowerCase().replace(/\s+/g, '-')],
  }];
}

export function currencyEvents(entry, data, now = Date.now()) {
  if (now - Date.parse(data.quotedAt) > 20 * 3600000 || Math.abs(data.changePercent) < entry.move) return [];
  const direction = data.changePercent >= 0 ? 'strengthens' : 'weakens';
  const base = entry.ticker.slice(0, 3);
  const magnitude = Math.abs(data.changePercent).toFixed(2);
  return [{
    key: `global:${entry.symbol}:${data.session}:${Math.sign(data.changePercent)}:${Math.trunc(Math.abs(data.changePercent) / entry.move)}`,
    title: `${base === 'USD' ? 'Dollar' : entry.name} ${direction} ${magnitude}% against the ${base === 'USD' ? entry.ticker.slice(3) : 'dollar'} to ${data.price.toFixed(entry.digits)}`,
    summary: `${entry.name} (${entry.ticker}) trades at ${data.price.toFixed(entry.digits)}, ${data.changePercent >= 0 ? 'up' : 'down'} ${magnitude}% from ${data.previousClose.toFixed(entry.digits)} at the prior close. Levels from Yahoo Finance as of ${data.quotedAt}.`,
    source: 'Yahoo Finance',
    url: url(entry.symbol),
    published_at: data.quotedAt,
    category: 'markets',
    priority: Math.abs(data.changePercent) >= entry.move * 2 ? 'urgent' : 'normal',
    tickers: [entry.ticker],
    tags: ['deterministic', 'currencies', 'global'],
  }];
}

export async function run() {
  const values = new Map();
  const failures = [];
  const symbols = [...indices, ...currencies].map(entry => entry.symbol);
  for (let start = 0; start < symbols.length; start += 4) {
    const batch = await quotes(symbols.slice(start, start + 4));
    for (const [symbol, value] of batch.values) values.set(symbol, value);
    failures.push(...batch.failures);
  }
  const events = [
    ...indices.flatMap(entry => values.has(entry.symbol) ? indexEvents(entry, values.get(entry.symbol)) : []),
    ...currencies.flatMap(entry => values.has(entry.symbol) ? currencyEvents(entry, values.get(entry.symbol)) : []),
  ];
  return { events, failures };
}
