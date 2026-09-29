import { getJson } from '../fetch.mjs';

export const id = 'treasury';

const dataset = 'https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v1/accounting/od/auctions_query';
const page = 'https://fiscaldata.treasury.gov/datasets/auctions-query/auctions-query';
const window = 36 * 3600000;
const plural = { Note: 'notes', Bond: 'bonds', TIPS: 'TIPS', FRN: 'FRNs' };

const present = value => (typeof value === 'string' && value !== 'null' && value.trim() ? value : null);
const billions = value => `$${Math.round(Number(value) / 1e9)}B`;
const shortDate = value => new Date(`${value}T12:00:00Z`).toUTCString().slice(5, 11);

function announce(record) {
  const amount = present(record.offering_amt);
  const term = record.security_term ?? record.security_type;
  const kind = plural[record.security_type] ?? 'securities';
  return {
    key: `treasury:announce:${record.cusip}`,
    title: `Treasury to auction ${amount ? billions(amount) : 'an unsized offering'} of ${term} ${kind} on ${shortDate(record.auction_date)}`,
    summary: `A Treasury announcement dated ${record.announcemt_date} schedules a ${term} ${record.security_type} offering${amount ? ` of ${billions(amount)}` : ''} under CUSIP ${record.cusip}. Terms from Treasury Fiscal Data; details can change before the auction.`,
    source: 'Treasury Fiscal Data',
    url: `${page}?cusip=${record.cusip}`,
    published_at: `${record.announcemt_date}T12:00:00Z`,
    category: 'markets',
    priority: 'normal',
    tickers: [],
    tags: ['deterministic', 'treasury', 'auction'],
  };
}

function result(record) {
  const high = present(record.high_yield);
  const cover = present(record.bid_to_cover_ratio);
  const accepted = present(record.total_accepted);
  const amount = present(record.offering_amt);
  const term = record.security_term ?? record.security_type;
  const kind = plural[record.security_type] ?? 'securities';
  const headline = [high ? `${high}% high yield` : null, cover ? `${Number(cover).toFixed(2)} bid-to-cover` : null].filter(Boolean).join(', ');
  return {
    key: `treasury:result:${record.cusip}`,
    title: `${term} ${kind} auction clears${headline ? ` at ${headline}` : ''}`,
    summary: `The ${term} ${record.security_type} auction dated ${record.auction_date} drew ${accepted ? `${billions(accepted)} in accepted bids` : 'its results'}${amount ? ` against a ${billions(amount)} offering` : ''}${high ? ` with a ${high}% high yield` : ''}${cover ? `, covering ${Number(cover).toFixed(2)} times the amount offered` : ''}. Results from Treasury Fiscal Data${record.record_date ? `, record dated ${record.record_date}` : ''}.`,
    source: 'Treasury Fiscal Data',
    url: `${page}?cusip=${record.cusip}`,
    published_at: `${record.auction_date}T18:00:00Z`,
    category: 'markets',
    priority: 'normal',
    tickers: [],
    tags: ['deterministic', 'treasury', 'auction'],
  };
}

export async function run() {
  const events = [];
  const failures = [];
  try {
    const feed = await getJson(`${dataset}?${new URLSearchParams({ filter: 'security_type:in:(Note,Bond,TIPS,FRN)', sort: '-auction_date', 'page[size]': '12' })}`, { timeout: 20000 });
    const now = Date.now();
    for (const record of feed.data ?? []) {
      const announced = Date.parse(`${record.announcemt_date ?? ''}T12:00:00Z`);
      if (Number.isFinite(announced) && announced <= now && now - announced <= window) events.push(announce(record));
      const auctioned = Date.parse(`${record.auction_date ?? ''}T18:00:00Z`);
      if (Number.isFinite(auctioned) && auctioned <= now && now - auctioned <= window && present(record.high_yield)) events.push(result(record));
    }
  } catch (error) {
    failures.push(`fiscaldata: ${error.message}`);
  }
  return { events, failures };
}
