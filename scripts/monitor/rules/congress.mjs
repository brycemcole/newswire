import { inflateRawSync } from 'node:zlib';
import { getText } from '../fetch.mjs';

export const id = 'congress';

const window = 10 * 86400000;

const watched = new Map([
  ['pelosi', 'Nancy Pelosi'],
  ['khanna', 'Ro Khanna'],
  ['greene', 'Marjorie Taylor Greene'],
  ['gottheimer', 'Josh Gottheimer'],
  ['crenshaw', 'Dan Crenshaw'],
  ['mccaul', 'Michael McCaul'],
  ['tuberville', 'Tommy Tuberville'],
  ['scott', 'Rick Scott'],
  ['whitehouse', 'Sheldon Whitehouse'],
  ['schumer', 'Chuck Schumer'],
  ['johnson', 'Mike Johnson'],
  ['jeffries', 'Hakeem Jeffries'],
]);

function textOf(block, tag) {
  return new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`).exec(block)?.[1]?.trim() ?? '';
}

function parseFilingDate(value) {
  const parts = value.split('/').map(Number);
  if (parts.length !== 3 || parts.some(part => !Number.isFinite(part))) return NaN;
  const [first, second, year] = parts;
  const [month, day] = first > 12 ? [second, first] : [first, second];
  return Date.parse(`${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}T12:00:00Z`);
}

async function archive(year) {
  const response = await fetch(`https://disclosures-clerk.house.gov/public_disc/financial-pdfs/${year}FD.ZIP`, {
    headers: { 'User-Agent': 'newswire-monitor bryce@localhost' },
    signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw new Error(`${response.status} House disclosure archive`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const start = findEntry(bytes);
  if (!start) throw new Error('No XML entry in House archive');
  return new TextDecoder('utf-8').decode(start);
}

function findEntry(bytes) {
  let offset = 0;
  while (offset < bytes.length - 4) {
    if (bytes[offset] === 0x50 && bytes[offset + 1] === 0x4b && bytes[offset + 2] === 0x03 && bytes[offset + 3] === 0x04) {
      const view = new DataView(bytes.buffer, bytes.byteOffset);
      const method = view.getUint16(offset + 8, true);
      const compressed = view.getUint32(offset + 18, true);
      const nameLength = view.getUint16(offset + 26, true);
      const extraLength = view.getUint16(offset + 28, true);
      const name = new TextDecoder().decode(bytes.slice(offset + 30, offset + 30 + nameLength));
      const dataStart = offset + 30 + nameLength + extraLength;
      if (name.toLowerCase().endsWith('.xml') && compressed) {
        const payload = bytes.slice(dataStart, dataStart + compressed);
        return method === 0 ? payload : inflateRawSync(payload);
      }
      offset = dataStart + (compressed || 1);
      continue;
    }
    offset += 1;
  }
  return null;
}

export async function run() {
  const events = [];
  const failures = [];
  const year = new Date().getUTCFullYear();
  let xml;
  try {
    xml = await archive(year);
  } catch (error) {
    return { events, failures: [`congress: ${error.message}`] };
  }

  for (const block of xml.match(/<Member>[\s\S]*?<\/Member>/g) ?? []) {
    if (textOf(block, 'FilingType') !== 'P') continue;
    const last = textOf(block, 'Last');
    const name = watched.get(last.toLowerCase());
    if (!name) continue;
    const filed = parseFilingDate(textOf(block, 'FilingDate'));
    if (!Number.isFinite(filed) || Date.now() - filed > window) continue;
    const docId = textOf(block, 'DocID');
    if (!docId) continue;
    const district = textOf(block, 'StateDst');
    events.push({
      key: `congress:ptr:${docId}`,
      title: `${name} files a periodic transaction report disclosing stock trades`,
      summary: `The House Clerk logged a periodic transaction report for ${name}${district ? ` (${district})` : ''} with a filing date of ${new Date(filed).toISOString().slice(0, 10)}. A periodic transaction report discloses purchases, sales, or exchanges by the member, a spouse, or a dependent child. The filing itself lists the assets, dates, and value ranges.`,
      source: 'US House Clerk',
      url: `https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/${year}/${docId}.pdf`,
      published_at: new Date(filed).toISOString(),
      category: 'politics',
      priority: 'urgent',
      tickers: [],
      tags: ['deterministic', 'congress', 'stock-trades'],
    });
  }
  return { events, failures };
}
