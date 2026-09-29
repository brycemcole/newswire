import { fred, quotes, signed } from '../fetch.mjs';

export const id = 'rates';

export async function run() {
  const events = [];
  const failures = [];
  const { values, failures: quoteFailures } = await quotes(['^TNX', 'DX-Y.NYB', 'CL=F', 'GC=F']);
  failures.push(...quoteFailures);

  const tnx = values.get('^TNX');
  if (tnx) {
    const basisPoints = (tnx.price - tnx.previousClose) * 100;
    if (Math.abs(basisPoints) >= 10) {
      events.push({
        key: `rates:ust10y:${tnx.session}:${basisPoints >= 0 ? 'up' : 'down'}:${Math.trunc(Math.abs(basisPoints) / 10)}`,
        title: `10-year Treasury yield moves ${signed(basisPoints, 0)} basis points to ${tnx.price.toFixed(2)}%`,
        summary: `The 10-year Treasury yield is ${tnx.price.toFixed(2)}%, ${signed(basisPoints, 0)} basis points from the prior close of ${tnx.previousClose.toFixed(2)}%. Levels from Yahoo Finance as of ${tnx.quotedAt}.`,
        source: 'Yahoo Finance',
        url: 'https://finance.yahoo.com/quote/%5ETNX',
        category: 'markets',
        priority: Math.abs(basisPoints) >= 20 ? 'urgent' : 'normal',
        tickers: ['UST10Y'],
        tags: ['deterministic', 'rates'],
      });
    }
    for (const line of [5, 4]) {
      if (tnx.price >= line && tnx.previousClose < line) {
        events.push({
          key: `rates:ust10y:cross${line}:${tnx.session}`,
          title: `10-year Treasury yield crosses ${line}%`,
          summary: `The 10-year Treasury yield rose through ${line}% to ${tnx.price.toFixed(2)}% from a prior close of ${tnx.previousClose.toFixed(2)}%. Levels from Yahoo Finance as of ${tnx.quotedAt}.`,
          source: 'Yahoo Finance',
          url: 'https://finance.yahoo.com/quote/%5ETNX',
          category: 'markets',
          priority: 'urgent',
          tickers: ['UST10Y'],
          tags: ['deterministic', 'rates'],
        });
        break;
      }
    }
  }

  const commodities = [
    { symbol: 'CL=F', name: 'WTI crude', ticker: 'CL', move: 4, unit: '$' },
    { symbol: 'GC=F', name: 'Gold', ticker: 'GC', move: 3, unit: '$' },
    { symbol: 'DX-Y.NYB', name: 'The dollar index', ticker: 'DXY', move: 1, unit: '' },
  ];
  for (const entry of commodities) {
    const data = values.get(entry.symbol);
    if (!data || Math.abs(data.changePercent) < entry.move) continue;
    events.push({
      key: `rates:${entry.symbol}:${data.session}:${data.changePercent >= 0 ? 'up' : 'down'}:${Math.trunc(Math.abs(data.changePercent))}`,
      title: `${entry.name} moves ${signed(data.changePercent, 1)}% to ${entry.unit}${data.price.toFixed(2)}`,
      summary: `${entry.name} is at ${entry.unit}${data.price.toFixed(2)}, ${signed(data.changePercent, 1)}% from a prior close of ${entry.unit}${data.previousClose.toFixed(2)}. Levels from Yahoo Finance as of ${data.quotedAt}.`,
      source: 'Yahoo Finance',
      url: `https://finance.yahoo.com/quote/${encodeURIComponent(entry.symbol)}`,
      category: 'markets',
      priority: Math.abs(data.changePercent) >= entry.move * 1.5 ? 'urgent' : 'normal',
      tickers: [entry.ticker],
      tags: ['deterministic', 'commodities'],
    });
  }

  try {
    const series = await fred(['BAMLH0A0HYM2', 'T10Y2Y']);
    const spread = series.get('BAMLH0A0HYM2');
    if (spread && spread.value >= 5) {
      events.push({
        key: `rates:hy-spread:${spread.date}`,
        title: `High-yield credit spread widens to ${spread.value.toFixed(2)} percentage points`,
        summary: `The ICE BofA US High Yield index option-adjusted spread reached ${spread.value.toFixed(2)} percentage points on ${spread.date}, a level associated with tightening credit conditions. Data from FRED.`,
        source: 'Federal Reserve Bank of St. Louis (FRED)',
        url: 'https://fred.stlouisfed.org/series/BAMLH0A0HYM2',
        category: 'economy',
        priority: spread.value >= 7 ? 'breaking' : 'urgent',
        tickers: [],
        tags: ['deterministic', 'credit'],
      });
    }
    const curve = series.get('T10Y2Y');
    if (curve && curve.value < 0) {
      events.push({
        key: `rates:curve-inversion:${curve.date.slice(0, 7)}`,
        title: `The 10-year/2-year Treasury curve is inverted at ${curve.value.toFixed(2)} points`,
        summary: `The spread between 10-year and 2-year Treasury yields was ${curve.value.toFixed(2)} percentage points on ${curve.date}, an inversion historically associated with recession risk. Data from FRED.`,
        source: 'Federal Reserve Bank of St. Louis (FRED)',
        url: 'https://fred.stlouisfed.org/series/T10Y2Y',
        category: 'economy',
        priority: 'urgent',
        tickers: [],
        tags: ['deterministic', 'rates', 'yield-curve'],
      });
    }
  } catch (error) {
    failures.push(`fred: ${error.message}`);
  }

  return { events, failures };
}
