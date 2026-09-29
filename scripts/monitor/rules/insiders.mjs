import { getJson, getText, money } from '../fetch.mjs';

export const id = 'insiders';

const headers = { 'User-Agent': 'newswire-monitor bryce@localhost' };
const window = 7 * 86400000;
const threshold = 2e6;

const companies = [
  { cik: '0001045810', name: 'Nvidia', symbol: 'NVDA' },
  { cik: '0000320193', name: 'Apple', symbol: 'AAPL' },
  { cik: '0000789019', name: 'Microsoft', symbol: 'MSFT' },
  { cik: '0001652044', name: 'Alphabet', symbol: 'GOOGL' },
  { cik: '0001018724', name: 'Amazon', symbol: 'AMZN' },
  { cik: '0001326801', name: 'Meta Platforms', symbol: 'META' },
  { cik: '0001318605', name: 'Tesla', symbol: 'TSLA' },
  { cik: '0001730168', name: 'Broadcom', symbol: 'AVGO' },
  { cik: '0000019617', name: 'JPMorgan Chase', symbol: 'JPM' },
  { cik: '0001067983', name: 'Berkshire Hathaway', symbol: 'BRK.B' },
];

const codes = {
  P: { verb: 'buys', label: 'open-market purchase', notable: true },
  S: { verb: 'sells', label: 'open-market sale', notable: true },
  A: { verb: 'is granted', label: 'grant or award', notable: false },
  M: { verb: 'exercises options for', label: 'option exercise', notable: false },
  F: { verb: 'surrenders', label: 'shares withheld for tax', notable: false },
  G: { verb: 'gifts', label: 'gift', notable: false },
};

function field(xml, tag) {
  return new RegExp(`<${tag}>\\s*(?:<value>)?\\s*([^<]*)`).exec(xml)?.[1]?.trim() ?? '';
}

function role(xml) {
  const title = field(xml, 'officerTitle');
  if (title) return title;
  if (field(xml, 'isDirector') === '1') return 'director';
  if (field(xml, 'isTenPercentOwner') === '1') return 'ten percent owner';
  return 'insider';
}

function personName(raw) {
  const clean = raw.replace(/\s+/g, ' ').trim();
  if (clean !== clean.toUpperCase()) return clean;
  return clean
    .toLowerCase()
    .split(' ')
    .map(part => part.length <= 1 ? `${part.toUpperCase()}.` : part[0].toUpperCase() + part.slice(1))
    .join(' ');
}

function transactions(xml) {
  const blocks = xml.match(/<nonDerivativeTransaction>[\s\S]*?<\/nonDerivativeTransaction>/g) ?? [];
  const totals = new Map();
  for (const block of blocks) {
    const code = field(block, 'transactionCode');
    const shares = Number(field(block, 'transactionShares'));
    const price = Number(field(block, 'transactionPricePerShare'));
    if (!codes[code] || !Number.isFinite(shares) || !Number.isFinite(price) || !shares) continue;
    const entry = totals.get(code) ?? { shares: 0, value: 0 };
    entry.shares += shares;
    entry.value += shares * price;
    totals.set(code, entry);
  }
  return totals;
}

async function scan(company, events) {
  const feed = await getJson(`https://data.sec.gov/submissions/CIK${company.cik}.json`, { headers, timeout: 25000 });
  const recent = feed.filings?.recent;
  if (!recent) return;
  const pending = [];
  for (let index = 0; index < (recent.form?.length ?? 0); index += 1) {
    if (recent.form[index] !== '4') continue;
    const filed = Date.parse(`${recent.filingDate[index]}T12:00:00Z`);
    if (!Number.isFinite(filed) || Date.now() - filed > window) continue;
    pending.push({ accession: recent.accessionNumber[index], document: recent.primaryDocument[index], filed, date: recent.filingDate[index] });
    if (pending.length >= 6) break;
  }

  for (const filing of pending) {
    const bare = filing.accession.replaceAll('-', '');
    const name = filing.document.includes('/') ? filing.document.split('/').pop() : filing.document;
    const directory = `https://www.sec.gov/Archives/edgar/data/${Number(company.cik)}/${bare}`;
    let xml;
    try {
      xml = await getText(`${directory}/${name}`, { headers, timeout: 20000 });
    } catch {
      continue;
    }
    const owner = field(xml, 'rptOwnerName');
    if (!owner) continue;
    const totals = transactions(xml);
    for (const [code, entry] of totals) {
      const meta = codes[code];
      if (!meta.notable || entry.value < threshold) continue;
      const person = personName(owner);
      events.push({
        key: `insiders:${filing.accession}:${code}`,
        title: `${company.name} ${role(xml)} ${person} ${meta.verb} $${money(entry.value)} of stock`,
        summary: `A Form 4 filed ${filing.date} reports ${person}, listed as ${role(xml)} at ${company.name} (${company.symbol}), in an ${meta.label} of ${entry.shares.toLocaleString('en-US')} shares worth about $${money(entry.value)}. Values are computed from the prices stated in the filing; consult the filing for conditions such as a 10b5-1 plan.`,
        source: 'SEC EDGAR',
        url: `${directory}/${filing.accession}-index.htm`,
        published_at: new Date(filing.filed).toISOString(),
        category: 'markets',
        priority: entry.value >= 5e7 || code === 'P' ? 'urgent' : 'normal',
        tickers: [company.symbol],
        tags: ['deterministic', 'insider', 'form-4'],
      });
    }
  }
}

export async function run() {
  const events = [];
  const failures = [];
  for (const company of companies) {
    try {
      await scan(company, events);
    } catch (error) {
      failures.push(`insiders ${company.symbol}: ${error.message}`);
    }
  }
  return { events, failures };
}
