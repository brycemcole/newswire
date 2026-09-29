import { getJson, marketSession, money, quotes, signed } from '../fetch.mjs';

export const id = 'equities';

const megacaps = [
  { symbol: 'AAPL', name: 'Apple', cik: '0000320193' },
  { symbol: 'MSFT', name: 'Microsoft', cik: '0000789019' },
  { symbol: 'NVDA', name: 'Nvidia', cik: '0001045810' },
  { symbol: 'GOOGL', name: 'Alphabet', cik: '0001652044' },
  { symbol: 'AMZN', name: 'Amazon', cik: '0001018724' },
  { symbol: 'META', name: 'Meta Platforms', cik: '0001326801' },
  { symbol: 'TSLA', name: 'Tesla', cik: '0001318605' },
  { symbol: 'JPM', name: 'JPMorgan Chase', cik: '0000019617' },
];

async function moves(events, failures) {
  const session = marketSession();
  if (session === 'closed') return;
  const { values, failures: quoteFailures } = await quotes(megacaps.map(entry => entry.symbol));
  failures.push(...quoteFailures);
  for (const entry of megacaps) {
    const data = values.get(entry.symbol);
    if (!data || Math.abs(data.changePercent) < 5) continue;
    events.push({
      key: `equities:${entry.symbol}:${data.session}:${data.changePercent >= 0 ? 'up' : 'down'}:${Math.trunc(Math.abs(data.changePercent) / 5)}`,
      title: `${entry.name} shares move ${signed(data.changePercent, 1)}% to $${money(data.price)}`,
      summary: `${entry.name} (${entry.symbol}) trades at $${money(data.price)}, ${signed(data.changePercent, 1)}% from a prior close of $${money(data.previousClose)}. Levels from Yahoo Finance as of ${data.quotedAt}; this alert reports the price move only and does not identify a cause.`,
      source: 'Yahoo Finance',
      url: `https://finance.yahoo.com/quote/${entry.symbol}`,
      category: 'markets',
      priority: Math.abs(data.changePercent) >= 10 ? 'urgent' : 'normal',
      tickers: [entry.symbol],
      tags: ['deterministic', 'equities', 'single-name'],
    });
  }
}

async function filings(events, failures) {
  const checks = megacaps.map(async entry => {
    const feed = await getJson(`https://data.sec.gov/submissions/CIK${entry.cik}.json`, { headers: { 'User-Agent': 'newswire-monitor bryce@localhost' }, timeout: 20000 });
    const recent = feed.filings?.recent;
    if (!recent) return;
    for (let index = 0; index < (recent.form?.length ?? 0); index += 1) {
      if (!['8-K', '8-K/A'].includes(recent.form[index])) continue;
      if ((recent.items?.[index] ?? '').includes('2.02')) continue;
      const filed = Date.parse(`${recent.filingDate[index]}T12:00:00Z`);
      if (!Number.isFinite(filed) || Date.now() - filed > 2 * 86400000) continue;
      const accession = recent.accessionNumber[index];
      const items = recent.items?.[index] ?? '';
      events.push({
        key: `equities:8k:${accession}`,
        title: `${entry.name} files an ${recent.form[index]} with the SEC`,
        summary: `${entry.name} (${entry.symbol}) filed a current report on ${recent.filingDate[index]}${items ? `, reporting under item(s) ${items}` : ''}. Filing identifier ${accession}; consult the filing for its contents.`,
        source: 'SEC EDGAR',
        url: `https://www.sec.gov/Archives/edgar/data/${Number(entry.cik)}/${accession.replaceAll('-', '')}/${accession}-index.htm`,
        published_at: new Date(filed).toISOString(),
        category: 'markets',
        priority: 'normal',
        tickers: [entry.symbol],
        tags: ['deterministic', 'sec-filing', '8-k'],
      });
      break;
    }
  });
  const settled = await Promise.allSettled(checks);
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`edgar ${megacaps[index].symbol}: ${entry.reason?.message ?? entry.reason}`); });
}

export async function run() {
  const events = [];
  const failures = [];
  await Promise.all([moves(events, failures), filings(events, failures)]);
  return { events, failures };
}
