import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { token } from './publish.mjs';

const directory = join(homedir(), '.config', 'newswire');
const stamp = join(directory, 'calendar-sync.json');
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const day = 86400000;
const runFile = promisify(execFile);
const date = ms => new Date(ms).toISOString().slice(0, 10);
const countries = { 'United States': 'USD', 'Euro Zone': 'EUR', Germany: 'EUR', France: 'EUR', Italy: 'EUR', Spain: 'EUR', 'United Kingdom': 'GBP', Japan: 'JPY', China: 'CNY', Canada: 'CAD', Australia: 'AUD', 'New Zealand': 'NZD', Switzerland: 'CHF', India: 'INR', Brazil: 'BRL', 'South Korea': 'KRW' };

export function historicalRows(rows) {
  if (!Array.isArray(rows)) throw new Error('Nasdaq calendar format changed');
  const clean = value => typeof value === 'string' ? value.replace(/&nbsp;/g, '').trim() : '';
  const seen = new Map();
  return rows.flatMap(row => {
    const country = countries[row.country], title = clean(row.eventName), actual = clean(row.actual), forecast = clean(row.consensus), previous = clean(row.previous);
    if (!country || !title || (!actual && !forecast && !previous)) return [];
    const key = `${country} ${title}`, index = (seen.get(key) ?? 0) + 1;
    seen.set(key, index);
    return [{ label: key, actual, forecast, previous, detail: `Nasdaq reported series ${index}; periodicity may be unspecified` }];
  });
}

async function post(path, body) {
  const response = await fetch(new URL(path, origin), { method: 'POST', headers: { Authorization: `Bearer ${await token()}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw new Error(`Worker ${response.status}`);
}

export async function syncCalendar({ force = false, backfill = 0 } = {}) {
  const last = JSON.parse(await readFile(stamp, 'utf8').catch(() => '{}')).at ?? 0;
  if (!force && !backfill && Date.now() - last < 3600000) return [];
  const failures = [];
  try {
    const response = await fetch('https://nfs.faireconomy.media/ff_calendar_thisweek.json', { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error(`ForexFactory ${response.status}`);
    const events = await response.json();
    if (!Array.isArray(events) || !events.length) throw new Error('ForexFactory returned no events');
    await post('/v1/econ/events', { events });
  } catch (error) { failures.push(`calendar: ${error.message}`); }
  const days = Math.max(7, Math.min(90, backfill || (last ? Math.ceil((Date.now() - last) / day) + 1 : 60)));
  for (let offset = 0; offset < days; offset++) {
    const at = date(Date.now() - offset * day);
    try {
      // Nasdaq's date-only endpoint uses the preceding US calendar day; verified against BLS release dates.
      const queryDate = date(Date.parse(at) + day);
      const response = await fetch(`https://api.nasdaq.com/api/calendar/economicevents?date=${queryDate}`, { headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'application/json' }, signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error(`Nasdaq ${response.status}`);
      const data = await response.json();
      if (data.status?.rCode !== 200 || (!Array.isArray(data.data?.rows) && !data.status?.bCodeMessage?.some(message => message.code === 1002))) throw new Error('Nasdaq returned no calendar payload');
      await post('/v1/econ/history', { date: at, rows: historicalRows(data.data?.rows ?? []) });
    } catch (error) { failures.push(`calendar history ${at}: ${error.message}`); }
  }
  failures.push(...await syncSeries());
  failures.push(...await syncSources());
  {
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(stamp, `${JSON.stringify({ at: Date.now() })}\n`, { mode: 0o600 });
  }
  return failures;
}

export async function syncSeries() {
  const failures = [];
  const ids = ['DFEDTARU','DFEDTARL','EFFR','SOFR','WALCL','PAYEMS','UNRATE','ICSA','JTSJOL','CES0500000003','CPIAUCNS','CPILFENS','CPIAUCSL','CPILFESL','PCEPILFE','T5YIE','GDPC1','UMCSENT','RSAFS','INDPRO','DGS2','DGS10','T10Y2Y','MORTGAGE30US','M2SL','BAMLC0A0CM','BAMLC0A4CBBB','BAMLH0A0HYM2','BAMLH0A3HYC','IRLTLT01DEM156N','IRLTLT01GBM156N','IRLTLT01JPM156N','IRLTLT01FRM156N','IRLTLT01ITM156N','IRLTLT01CAM156N','IRLTLT01AUM156N','WPU101','PPIACO','PPIFIS','A191RL1Q225SBEA'];
  let next = 0;
  await Promise.all(Array.from({ length: 3 }, async () => {
    while (next < ids.length) {
      const id = ids[next++];
      try {
        const start = date(Date.now() - 6 * 365 * day);
        const url = `https://fred.stlouisfed.org/graph/fredgraph.csv?id=${id}&cosd=${start}`;
        let csv;
        try {
          const response = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'text/csv' }, signal: AbortSignal.timeout(4000) });
          if (!response.ok) throw new Error(`FRED ${response.status}`);
          csv = await response.text();
        } catch {
          const { stdout } = await runFile('curl', ['-4', '--fail', '--silent', '--show-error', '--max-time', '4', '-A', 'Mozilla/5.0', url], { maxBuffer: 512000 });
          csv = stdout;
        }
        const lines = csv.trim().split('\n');
        if (!lines[0].startsWith('observation_date,')) throw new Error('FRED CSV format changed');
        const observations = lines.slice(1).flatMap(line => { const [at, raw] = line.trim().split(','); const value = Number(raw); return raw && raw !== '.' && Number.isFinite(value) ? [{ date: at, value }] : []; });
        await post('/v1/econ/series', { id, observations });
      } catch (error) { failures.push(`economic snapshot ${id}: ${error.message}`); }
    }
  }));
  return failures;
}

export function publicSourceRows(xml) {
  const clean = value => value.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/<[^>]*>/g, '').trim();
  return [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].slice(0, 60).map(([, item]) => {
    const field = tag => clean(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`).exec(item)?.[1] ?? '');
    const at = Date.parse(field('pubDate'));
    return { label: field('title').slice(0, 500), value: field('source').slice(0, 200), url: field('link'), date: Number.isFinite(at) ? new Date(at).toISOString() : undefined, detail: field('description').slice(0, 600) };
  }).filter(row => row.label && row.url.startsWith('https://news.google.com/'));
}

export async function syncSources() {
  try {
    const queries = ['(payrolls OR unemployment OR jobs) (forecast OR consensus) when:60d', '(CPI OR inflation OR PCE) (forecast OR consensus) when:60d', '(Fed OR economy OR GDP OR central bank) when:14d'];
    const rows = [];
    for (const q of queries) {
      const response = await fetch(`https://news.google.com/rss/search?q=${encodeURIComponent(q)}&hl=en-US&gl=US&ceid=US:en`, { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error(`Google News ${response.status}`);
      rows.push(...publicSourceRows(await response.text()));
    }
    await post('/v1/econ/sources', { rows: [...new Map(rows.map(row => [row.url, row])).values()] });
    return [];
  } catch (error) { return [`public coverage: ${error.message}`]; }
}
