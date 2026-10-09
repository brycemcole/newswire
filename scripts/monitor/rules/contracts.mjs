import { getJson } from '../fetch.mjs';

export const id = 'contracts';

const threshold = 250e6;
const contractors = [
  [/lockheed/i, 'LMT'], [/raytheon|\brtx\b/i, 'RTX'], [/general dynamics|electric boat|bath iron|gulfstream/i, 'GD'], [/northrop/i, 'NOC'],
  [/boeing/i, 'BA'], [/l3harris|harris corp/i, 'LHX'], [/huntington ingalls|newport news ship/i, 'HII'], [/leidos/i, 'LDOS'], [/palantir/i, 'PLTR'],
  [/booz allen/i, 'BAH'], [/science applications|\bsaic\b/i, 'SAIC'], [/caci/i, 'CACI'], [/honeywell/i, 'HON'], [/general electric|ge aerospace/i, 'GE'],
  [/textron|bell textron/i, 'TXT'], [/oshkosh/i, 'OSK'], [/kbr/i, 'KBR'], [/parsons/i, 'PSN'], [/bae systems/i, 'BAESY'], [/amentum/i, 'AMTM'],
  [/microsoft/i, 'MSFT'], [/amazon web services|amazon\.com/i, 'AMZN'], [/oracle/i, 'ORCL'], [/google/i, 'GOOGL'], [/kratos/i, 'KTOS'], [/aerovironment/i, 'AVAV'],
];
const billions = value => value >= 1e9 ? `$${(value / 1e9).toFixed(2)} billion` : `$${Math.round(value / 1e6)} million`;
const titleCase = name => name.toLowerCase().replace(/\b([a-z])/g, letter => letter.toUpperCase()).replace(/\b(Llc|Inc|Usg|Lp|Jv)\b/g, word => word.toUpperCase());

export async function run() {
  const start = new Date(Date.now() - 10 * 86400000).toISOString().slice(0, 10);
  const feed = await getJson('https://api.usaspending.gov/api/v2/search/spending_by_transaction/', {
    method: 'POST', timeout: 30000,
    body: JSON.stringify({
      filters: { agencies: [{ type: 'awarding', tier: 'toptier', name: 'Department of Defense' }], award_type_codes: ['A', 'B', 'C', 'D'], time_period: [{ start_date: start, end_date: new Date().toISOString().slice(0, 10) }] },
      fields: ['Award ID', 'Recipient Name', 'Transaction Amount', 'Action Date', 'Transaction Description', 'Awarding Sub Agency', 'generated_internal_id'],
      limit: 25, sort: 'Transaction Amount', order: 'desc',
    }),
  });
  const events = [];
  for (const row of feed.results ?? []) {
    const amount = Number(row['Transaction Amount']);
    if (!Number.isFinite(amount) || amount < threshold) continue;
    const recipient = titleCase(String(row['Recipient Name'] ?? 'Unknown contractor'));
    const agency = row['Awarding Sub Agency'] || 'the Defense Department';
    const description = String(row['Transaction Description'] ?? '').trim().replace(/\s+/g, ' ');
    const ticker = contractors.find(([pattern]) => pattern.test(recipient))?.[1];
    events.push({
      key: `contracts:${row.generated_internal_id}:${row['Action Date']}:${Math.round(amount / 1e6)}`,
      title: `${recipient} awarded ${billions(amount)} ${agency.replace(/^Department of the /, '')} contract action`,
      summary: `${agency} obligated ${billions(amount)} to ${recipient} on ${row['Action Date']} under award ${row['Award ID']}${description ? `: ${description.slice(0, 400).toLowerCase()}` : ''}. Figures are contract obligations reported to USAspending.gov, which can trail the Pentagon's daily announcements and may include modifications to existing awards.`,
      source: 'USAspending.gov',
      url: `https://www.usaspending.gov/award/${row.generated_internal_id}`,
      published_at: `${row['Action Date']}T21:00:00Z`,
      category: 'politics',
      priority: amount >= 1e9 ? 'urgent' : 'normal',
      tickers: ticker ? [ticker] : [],
      tags: ['deterministic', 'defense', 'contracts', 'government-spending'],
    });
  }
  return { events, failures: [] };
}
