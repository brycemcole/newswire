import { getJson } from '../fetch.mjs';

export const id = 'earnings';

const watchlist = [
  { symbol: 'AAPL', name: 'Apple', cik: '0000320193' },
  { symbol: 'MSFT', name: 'Microsoft', cik: '0000789019' },
  { symbol: 'NVDA', name: 'Nvidia', cik: '0001045810' },
  { symbol: 'GOOGL', name: 'Alphabet', cik: '0001652044' },
  { symbol: 'AMZN', name: 'Amazon', cik: '0001018724' },
  { symbol: 'META', name: 'Meta Platforms', cik: '0001326801' },
  { symbol: 'TSLA', name: 'Tesla', cik: '0001318605' },
  { symbol: 'JPM', name: 'JPMorgan Chase', cik: '0000019617' },
  { symbol: 'AMD', name: 'AMD', cik: '0000002488' },
  { symbol: 'NFLX', name: 'Netflix', cik: '0001065280' },
  { symbol: 'DIS', name: 'Walt Disney', cik: '0001744489' },
  { symbol: 'BAC', name: 'Bank of America', cik: '0000070858' },
  { symbol: 'XOM', name: 'Exxon Mobil', cik: '0000034088' },
  { symbol: 'KO', name: 'Coca-Cola', cik: '0000021344' },
];

export async function run() {
  const events = [];
  const failures = [];
  const checks = watchlist.map(async entry => {
    const feed = await getJson(`https://data.sec.gov/submissions/CIK${entry.cik}.json`, { headers: { 'User-Agent': 'newswire-monitor bryce@localhost' }, timeout: 20000 });
    const recent = feed.filings?.recent;
    if (!recent) return;
    for (let index = 0; index < (recent.form?.length ?? 0); index += 1) {
      if (!['8-K', '8-K/A'].includes(recent.form[index])) continue;
      if (!(recent.items?.[index] ?? '').includes('2.02')) continue;
      const filed = Date.parse(`${recent.filingDate[index]}T12:00:00Z`);
      if (!Number.isFinite(filed) || Date.now() - filed > 2 * 86400000) continue;
      const accession = recent.accessionNumber[index];
      events.push({
        key: `earnings:8k:${accession}`,
        title: `${entry.name} reports quarterly results`,
        summary: `${entry.name} (${entry.symbol}) filed a ${recent.form[index]} on ${recent.filingDate[index]} under item 2.02, the results-of-operations item companies use to announce earnings. Filing identifier ${accession}. This alert registers the report; consult the filing or the company release for the figures.`,
        source: 'SEC EDGAR',
        url: `https://www.sec.gov/Archives/edgar/data/${Number(entry.cik)}/${accession.replaceAll('-', '')}/${accession}-index.htm`,
        published_at: new Date(filed).toISOString(),
        category: 'markets',
        priority: 'urgent',
        tickers: [entry.symbol],
        tags: ['deterministic', 'earnings', 'sec-filing'],
      });
      break;
    }
  });
  const settled = await Promise.allSettled(checks);
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`edgar ${watchlist[index].symbol}: ${entry.reason?.message ?? entry.reason}`); });
  return { events, failures };
}
