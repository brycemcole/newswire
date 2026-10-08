import { cached, quote, type Quote } from './quotes';

export interface DataEnv { DB: D1Database; FRED_API_KEY?: string }
export class DataError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export interface Row {
  label: string; value: string; detail?: string; change?: number; change_label?: string; date?: string;
  symbol?: string; series?: string; story?: string; url?: string; destination?: string; points?: number[];
  forecast?: string; previous?: string; actual?: string; surprise?: number; ptr_id?: string; ptr_year?: number;
}
export interface Pin { lat: number; lon: number; label: string; detail?: string; heading?: number; kind?: string }
export interface Section { title: string; rows: Row[] }
export interface Point { x: string; value: number }
export interface Payload {
  title: string; source: string; url: string; as_of: string; note?: string;
  sections: Section[]; page?: { total: number; offset: number; limit: number }; chart?: { label: string; unit?: string; points: Point[] }; map?: { center: [number, number]; span: number; pins: Pin[] }; text: string;
}
type Draft = Omit<Payload, 'text' | 'as_of'> & { as_of?: string };
type Args = Record<string, string>;
interface Param { type: 'string' | 'number'; description: string; enum?: string[]; required?: boolean }
interface Tool { name: string; path: string; description: string; params: Record<string, Param>; run(args: Args, env: DataEnv): Promise<Draft> }

const agent = 'Mozilla/5.0 (compatible; Newswire/1.0)';
const sec = 'bryce-newswire admin@bryce-newswire.workers.dev';
const day = 86400000;
const iso = (ms = Date.now()) => new Date(ms).toISOString();
const ymd = (ms = Date.now()) => iso(ms).slice(0, 10);
const round = (value: number, places = 2) => Math.round(value * 10 ** places) / 10 ** places;
const fmt = (value: number, places = 2) => value.toLocaleString('en-US', { minimumFractionDigits: places, maximumFractionDigits: places });
const money = (value: number) => {
  const abs = Math.abs(value);
  const [div, unit] = abs >= 1e12 ? [1e12, 'T'] : abs >= 1e9 ? [1e9, 'B'] : abs >= 1e6 ? [1e6, 'M'] : abs >= 1e3 ? [1e3, 'K'] : [1, ''];
  return `${value < 0 ? '−' : ''}$${fmt(abs / div, unit ? 1 : 0)}${unit}`;
};
const signed = (value: number, places = 2, suffix = '') => `${value > 0 ? '+' : value < 0 ? '−' : ''}${fmt(Math.abs(value), places)}${suffix}`;

async function mapLimited<T, U>(items: T[], load: (item: T, index: number) => Promise<U>, width = 3): Promise<U[]> {
  const result = new Array<U>(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(width, items.length) }, async () => {
    while (next < items.length) { const index = next++; result[index] = await load(items[index], index); }
  }));
  return result;
}

async function get(url: string, init: RequestInit & { timeout?: number } = {}): Promise<Response> {
  const response = await fetch(url, { ...init, headers: { 'User-Agent': url.includes('yahoo.com') ? agent : sec, ...init.headers }, signal: AbortSignal.timeout(init.timeout ?? 8000) });
  if (!response.ok) throw new DataError(502, `${new URL(url).hostname} returned ${response.status}`);
  return response;
}
const getJSON = async <T>(url: string, init?: RequestInit & { timeout?: number }) => (await get(url, init)).json() as Promise<T>;
const getText = async (url: string, init?: RequestInit & { timeout?: number }) => (await get(url, init)).text();

function text(value: string | undefined, name: string, max: number, required = false): string {
  const clean = (value ?? '').trim();
  if (required && !clean) throw new DataError(400, `Missing ${name}`);
  if (clean.length > max || clean.includes('\0')) throw new DataError(400, `Invalid ${name}`);
  return clean;
}
function number(value: string | undefined, name: string, min: number, max: number, fallback: number): number {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || (['days', 'limit'].includes(name) && !Number.isInteger(parsed)) || parsed < min || parsed > max) throw new DataError(400, `Invalid ${name}`);
  return parsed;
}
function pick(value: string | undefined, name: string, options: string[], fallback: string): string {
  const clean = (value ?? fallback).trim().toLowerCase() || fallback;
  if (!options.includes(clean)) throw new DataError(400, `Invalid ${name}; use ${options.join(', ')}`);
  return clean;
}

export function render(payload: Omit<Payload, 'text'>): string {
  const lines = [`${payload.title}`, `Source: ${payload.source} ${payload.url} · as of ${payload.as_of}`];
  if (payload.note) lines.push(payload.note);
  for (const section of payload.sections) {
    lines.push('', `${section.title}:`);
    const rows = section.title === 'All reported positions' ? section.rows.slice(0, 25) : section.rows;
    for (const row of rows) {
      const change = row.change_label ?? (row.change !== undefined ? signed(row.change, 2, '%') : '');
      lines.push(`- ${row.label}${row.symbol && row.symbol !== row.label ? ` (${row.symbol})` : ''}: ${row.value}${change ? ` (${change})` : ''}${row.detail ? ` · ${row.detail}` : ''}${row.date ? ` · ${row.date}` : ''}${row.url ? ` ${row.url}` : ''}`);
    }
    if (rows.length < section.rows.length) lines.push(`… ${payload.page?.total ?? section.rows.length} reported positions available in pages.`);
  }
  if (payload.chart?.points.length) {
    const points = payload.chart.points;
    const step = Math.max(1, Math.ceil(points.length / 24));
    lines.push('', `${payload.chart.label}${payload.chart.unit ? ` (${payload.chart.unit})` : ''}: ${points.filter((_, i) => i % step === 0 || i === points.length - 1).map(p => `${p.x} ${p.value}`).join('; ')}`);
  }
  return lines.join('\n');
}

// FRED

interface Spec { id: string; label: string; unit: string; transform?: 'yoy' | 'diff'; places?: number }
const catalog: { key: string; title: string; items: Spec[] }[] = [
  { key: 'fed', title: 'Fed policy', items: [
    { id: 'DFEDTARU', label: 'Fed target, upper', unit: '%' }, { id: 'DFEDTARL', label: 'Fed target, lower', unit: '%' },
    { id: 'EFFR', label: 'Effective fed funds', unit: '%' }, { id: 'SOFR', label: 'SOFR', unit: '%' },
    { id: 'WALCL', label: 'Fed balance sheet', unit: '$M', places: 0 },
  ] },
  { key: 'jobs', title: 'Jobs', items: [
    { id: 'PAYEMS', label: 'Nonfarm payrolls, monthly change', unit: 'K', transform: 'diff', places: 0 }, { id: 'UNRATE', label: 'Unemployment rate', unit: '%', places: 1 },
    { id: 'ICSA', label: 'Initial jobless claims', unit: '', places: 0 }, { id: 'JTSJOL', label: 'Job openings', unit: 'K', places: 0 },
    { id: 'CES0500000003', label: 'Average hourly earnings, y/y', unit: '%', transform: 'yoy', places: 1 },
  ] },
  { key: 'inflation', title: 'Inflation', items: [
    { id: 'CPIAUCNS', label: 'CPI, y/y', unit: '%', transform: 'yoy', places: 1 }, { id: 'CPILFENS', label: 'Core CPI, y/y', unit: '%', transform: 'yoy', places: 1 },
    { id: 'PCEPILFE', label: 'Core PCE, y/y', unit: '%', transform: 'yoy', places: 1 }, { id: 'T5YIE', label: '5-year breakeven inflation', unit: '%' },
  ] },
  { key: 'growth', title: 'Growth', items: [
    { id: 'GDPC1', label: 'Real GDP, y/y', unit: '%', transform: 'yoy', places: 1 }, { id: 'UMCSENT', label: 'Consumer sentiment', unit: '', places: 1 },
    { id: 'RSAFS', label: 'Retail sales, y/y', unit: '%', transform: 'yoy', places: 1 }, { id: 'INDPRO', label: 'Industrial production, y/y', unit: '%', transform: 'yoy', places: 1 },
  ] },
  { key: 'rates', title: 'Rates and money', items: [
    { id: 'DGS2', label: '2-year Treasury', unit: '%' }, { id: 'DGS10', label: '10-year Treasury', unit: '%' },
    { id: 'T10Y2Y', label: '10-year minus 2-year', unit: 'pp' }, { id: 'MORTGAGE30US', label: '30-year mortgage', unit: '%' },
    { id: 'M2SL', label: 'M2 money supply, y/y', unit: '%', transform: 'yoy', places: 1 },
  ] },
  { key: 'credit', title: 'Credit spreads', items: [
    { id: 'BAMLC0A0CM', label: 'Investment grade OAS', unit: '%' }, { id: 'BAMLC0A4CBBB', label: 'BBB OAS', unit: '%' },
    { id: 'BAMLH0A0HYM2', label: 'High yield OAS', unit: '%' }, { id: 'BAMLH0A3HYC', label: 'CCC and lower OAS', unit: '%' },
  ] },
  { key: 'global', title: 'Global 10-year yields (monthly average)', items: [
    { id: 'IRLTLT01DEM156N', label: 'Germany', unit: '%' }, { id: 'IRLTLT01GBM156N', label: 'United Kingdom', unit: '%' },
    { id: 'IRLTLT01JPM156N', label: 'Japan', unit: '%' }, { id: 'IRLTLT01FRM156N', label: 'France', unit: '%' },
    { id: 'IRLTLT01ITM156N', label: 'Italy', unit: '%' }, { id: 'IRLTLT01CAM156N', label: 'Canada', unit: '%' },
    { id: 'IRLTLT01AUM156N', label: 'Australia', unit: '%' },
  ] },
  { key: 'prices', title: 'Producer prices', items: [
    { id: 'WPU101', label: 'Iron and steel PPI, y/y', unit: '%', transform: 'yoy', places: 1 }, { id: 'PPIACO', label: 'All commodities PPI, y/y', unit: '%', transform: 'yoy', places: 1 },
  ] },
];
const specs = new Map(catalog.flatMap(group => group.items.map(item => [item.id, item] as const)));

interface Observation { date: string; value: number }
interface SeriesData { id: string; title: string; units: string; frequency: string; updated: string; observations: Observation[] }

async function fred(id: string, env: DataEnv, start: string): Promise<SeriesData> {
  const saved = await env.DB.prepare('SELECT payload, updated_at FROM econ_series WHERE id = ?').bind(id).first<{ payload: string; updated_at: string }>();
  const snapshot = (failed: boolean): SeriesData => {
    const data = JSON.parse(saved!.payload) as SeriesData;
    return { ...data, title: data.title.replace(/, (?:y\/y|monthly change)$/, ''), units: specs.get(id)?.transform === 'yoy' ? '' : data.units, updated: `collector snapshot ${saved!.updated_at}${failed ? '; upstream unavailable' : ''}`, observations: data.observations.filter(o => o.date >= start) };
  };
  if (saved && Date.now() - Date.parse(saved.updated_at) < 3600000 && start >= (JSON.parse(saved.payload) as SeriesData).observations[0]?.date) return snapshot(false);
  try { return await cached(`fred/v2/${id}/${start}/${env.FRED_API_KEY ? 'api' : 'csv'}`, 3600, async () => {
    if (env.FRED_API_KEY) {
      const key = encodeURIComponent(env.FRED_API_KEY);
      const [meta, data] = await Promise.all([
        getJSON<{ seriess?: { title: string; units: string; frequency: string; last_updated: string }[] }>(`https://api.stlouisfed.org/fred/series?series_id=${id}&api_key=${key}&file_type=json`),
        getJSON<{ observations?: { date: string; value: string }[] }>(`https://api.stlouisfed.org/fred/series/observations?series_id=${id}&api_key=${key}&file_type=json&observation_start=${start}`),
      ]);
      const info = meta.seriess?.[0];
      if (!info) throw new DataError(404, `No FRED series ${id}`);
      return { id, title: info.title, units: info.units, frequency: info.frequency, updated: info.last_updated,
        observations: (data.observations ?? []).filter(o => o.value.trim() !== '' && o.value !== '.').map(o => ({ date: o.date, value: Number(o.value) })).filter(o => Number.isFinite(o.value)) };
    }
    const response = await fetch(`https://fred.stlouisfed.org/graph/fredgraph.csv?id=${id}&cosd=${start}`, { headers: { 'User-Agent': sec, Accept: 'text/csv' }, signal: AbortSignal.timeout(8000) });
    if (response.status === 404) throw new DataError(404, `No FRED series ${id}`);
    if (!response.ok) throw new DataError(502, `FRED returned ${response.status}`);
    const lines = (await response.text()).trim().split('\n');
    if (!lines[0]?.includes(',')) throw new DataError(404, `No FRED series ${id}`);
    const observations = lines.slice(1).flatMap(line => {
      const [date, raw = ''] = line.split(',');
      const value = Number(raw);
      return date && raw.trim() && raw.trim() !== '.' && Number.isFinite(value) ? [{ date: date.trim(), value }] : [];
    });
    const spec = specs.get(id);
    return { id, title: spec?.label.replace(/, (?:y\/y|monthly change)$/, '') ?? id, units: spec?.transform === 'yoy' ? '' : spec?.unit ?? '', frequency: '', updated: '', observations };
  }); } catch (error) {
    if (!saved || Date.now() - Date.parse(saved.updated_at) > 7 * day) throw error;
    return snapshot(true);
  }
}

function before(values: Observation[], ms: number): Observation | undefined {
  for (let i = values.length - 1; i >= 0; i--) if (Date.parse(values[i].date) <= ms) return values[i];
  return undefined;
}

function transformed(observations: Observation[], transform: Spec['transform']): Observation[] {
  if (!transform) return observations;
  return observations.flatMap((point, index) => {
    if (transform === 'diff') return index ? [{ date: point.date, value: point.value - observations[index - 1].value }] : [];
    const target = Date.parse(point.date) - 365 * day;
    const base = before(observations, target + 5 * day);
    return base && Date.parse(base.date) >= target - 40 * day ? [{ date: point.date, value: (point.value / base.value - 1) * 100 }] : [];
  });
}

const seriesID = (value: string | undefined) => {
  const id = text(value, 'id', 40, true).toUpperCase();
  if (!/^[A-Z0-9_.]{2,40}$/.test(id)) throw new DataError(400, 'Invalid id');
  return id;
};
const fredURL = (id: string) => `https://fred.stlouisfed.org/series/${id}`;
const thin = <T>(values: T[], max: number) => values.length <= max ? values : Array.from({ length: max }, (_, i) => values[Math.round(i * (values.length - 1) / (max - 1))]);

async function latest(spec: Spec, env: DataEnv): Promise<Row> {
  const start = ymd(Date.now() - (spec.transform === 'yoy' ? 3 : 2) * 365 * day);
  try {
    const data = await fred(spec.id, env, start);
    const values = transformed(data.observations, spec.transform);
    const last = values.at(-1), previous = values.at(-2);
    if (!last) throw new Error('empty');
    const places = spec.places ?? 2;
    const unit = spec.unit === '%' || spec.unit === 'pp' ? spec.unit === '%' ? '%' : ' pp' : spec.unit ? ` ${spec.unit}` : '';
    const delta = previous ? last.value - previous.value : undefined;
    return { label: spec.label, value: `${spec.transform === 'diff' ? signed(last.value, places) : fmt(last.value, places)}${unit}`, date: last.date, series: spec.id,
      detail: data.updated.includes('collector snapshot') ? data.updated : undefined, change_label: delta === undefined ? undefined : `${signed(delta, places)} vs prior`, points: thin(values.slice(-36).map(v => round(v.value, 3)), 36) };
  } catch {
    return { label: spec.label, value: 'unavailable', detail: 'Upstream lookup failed; retry this id with series. Do not infer a value.', series: spec.id };
  }
}

// Yahoo

async function quoteRows(symbols: [string, string][]): Promise<Row[]> {
  const loaded = await Promise.all(symbols.map(async ([symbol, label]) => ({ label, symbol, value: await quote(symbol) })));
  return loaded.map(({ label, symbol, value }) => value ? quoteRow(value, label) : { label, symbol, value: 'unavailable' });
}
function quoteRow(q: Omit<Quote, 'match'>, label?: string): Row {
  const minor = minorCurrency(q.currency);
  const price = minor ? q.price / 100 : q.price;
  return { label: label ?? q.name, symbol: q.symbol, value: `${fmt(price, price >= 1000 ? 0 : price < 10 ? 4 : 2)}${q.currency && q.currency !== 'USD' ? ` ${minor ?? q.currency}` : ''}`,
    change: round(q.changePercent), date: q.time, points: q.points };
}
export function minorCurrency(code: string): string | null {
  return ({ GBp: 'GBP', GBX: 'GBP', ILA: 'ILS', ZAc: 'ZAR', ZAC: 'ZAR' } as Record<string, string>)[code] ?? null;
}

const boards: Record<string, { title: string; sections: { title: string; symbols: [string, string][] }[] }> = {
  world: { title: 'World equity indices', sections: [
    { title: 'Americas', symbols: [['^GSPC', 'S&P 500'], ['^IXIC', 'Nasdaq Composite'], ['^DJI', 'Dow Jones'], ['^RUT', 'Russell 2000'], ['^GSPTSE', 'S&P/TSX'], ['^BVSP', 'Bovespa'], ['^MXX', 'IPC Mexico']] },
    { title: 'Europe', symbols: [['^STOXX50E', 'Euro Stoxx 50'], ['^FTSE', 'FTSE 100'], ['^GDAXI', 'DAX'], ['^FCHI', 'CAC 40'], ['FTSEMIB.MI', 'FTSE MIB'], ['^IBEX', 'IBEX 35'], ['^SSMI', 'SMI']] },
    { title: 'Asia-Pacific', symbols: [['^N225', 'Nikkei 225'], ['^HSI', 'Hang Seng'], ['000001.SS', 'Shanghai Composite'], ['^KS11', 'KOSPI'], ['^TWII', 'Taiwan Weighted'], ['^AXJO', 'S&P/ASX 200'], ['^NSEI', 'Nifty 50']] },
  ] },
  fx: { title: 'Currencies', sections: [
    { title: 'Majors', symbols: [['DX-Y.NYB', 'Dollar index'], ['EURUSD=X', 'EUR/USD'], ['GBPUSD=X', 'GBP/USD'], ['JPY=X', 'USD/JPY'], ['CHF=X', 'USD/CHF'], ['CAD=X', 'USD/CAD'], ['AUDUSD=X', 'AUD/USD']] },
    { title: 'Emerging and Asia', symbols: [['CNY=X', 'USD/CNY'], ['INR=X', 'USD/INR'], ['KRW=X', 'USD/KRW'], ['MXN=X', 'USD/MXN'], ['BRL=X', 'USD/BRL'], ['TRY=X', 'USD/TRY']] },
    { title: 'Crypto', symbols: [['BTC-USD', 'Bitcoin'], ['ETH-USD', 'Ether']] },
  ] },
  commodities: { title: 'Commodities', sections: [
    { title: 'Energy', symbols: [['CL=F', 'WTI crude'], ['BZ=F', 'Brent crude'], ['NG=F', 'Natural gas'], ['RB=F', 'RBOB gasoline'], ['HO=F', 'Heating oil']] },
    { title: 'Metals', symbols: [['GC=F', 'Gold'], ['SI=F', 'Silver'], ['HG=F', 'Copper'], ['PL=F', 'Platinum'], ['PA=F', 'Palladium'], ['HRC=F', 'US hot-rolled steel']] },
    { title: 'Agriculture', symbols: [['ZC=F', 'Corn'], ['ZW=F', 'Wheat'], ['ZS=F', 'Soybeans'], ['KC=F', 'Coffee'], ['SB=F', 'Sugar'], ['CC=F', 'Cocoa'], ['LE=F', 'Live cattle']] },
  ] },
  rates: { title: 'US rates', sections: [
    { title: 'Treasury yields', symbols: [['^IRX', '13-week bill'], ['^FVX', '5-year'], ['^TNX', '10-year'], ['^TYX', '30-year']] },
    { title: 'Futures', symbols: [['ZQ=F', '30-day fed funds'], ['ZT=F', '2-year note'], ['ZN=F', '10-year note'], ['ZB=F', 'Treasury bond']] },
  ] },
};

interface YahooSession { cookie: string; crumb: string }
async function yahooSession(refresh = false): Promise<YahooSession> {
  const load = async () => {
    const first = await fetch('https://fc.yahoo.com', { headers: { 'User-Agent': agent }, redirect: 'manual', signal: AbortSignal.timeout(6000) });
    const cookie = first.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
    const crumb = await (await get('https://query2.finance.yahoo.com/v1/test/getcrumb', { headers: { Cookie: cookie } })).text();
    if (!crumb || crumb.includes('<')) throw new DataError(502, 'Yahoo session unavailable');
    return { cookie, crumb };
  };
  return refresh ? load() : cached('yahoo/session/v1', 3600, load);
}
async function yahooAuthed<T>(url: string, init: RequestInit = {}): Promise<T> {
  for (const refresh of [false, true]) {
    const session = await yahooSession(refresh);
    const response = await fetch(`${url}${url.includes('?') ? '&' : '?'}crumb=${encodeURIComponent(session.crumb)}`, { ...init, headers: { 'User-Agent': agent, Cookie: session.cookie, ...init.headers }, signal: AbortSignal.timeout(8000) });
    if (response.status === 401 || response.status === 403) continue;
    if (!response.ok) throw new DataError(502, `Yahoo returned ${response.status}`);
    return response.json() as Promise<T>;
  }
  throw new DataError(502, 'Yahoo rejected the session');
}

function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
function yahooRaw(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  const raw = objectValue(value).raw;
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : undefined;
}
function yahooFormatted(value: unknown): string | undefined {
  if (typeof value === 'string') return value;
  const formatted = objectValue(value).fmt;
  if (typeof formatted === 'string' && formatted) return formatted;
  const raw = yahooRaw(value);
  return raw === undefined ? undefined : String(raw);
}

// Economic calendar: ForexFactory publishes only the current week, so every fetch is kept in D1 and last week's forecasts survive.

interface EconEvent { id: string; country: string; title: string; at: string; impact: string; forecast: string; previous: string }
async function econEvents(env: DataEnv): Promise<EconEvent[]> {
  const { results } = await env.DB.prepare('SELECT * FROM econ_events WHERE at >= ? ORDER BY at').bind(iso(Date.now() - 8 * day)).all<EconEvent>();
  return results;
}

/** ForexFactory rate-limits Cloudflare's shared egress, so the Mac mini monitor fetches the week and posts it here. */
export async function storeEconEvents(value: unknown, env: DataEnv) {
  const list = (value as { events?: unknown } | null)?.events;
  if (!Array.isArray(list) || !list.length || list.length > 400) throw new DataError(400, 'Expected 1-400 events');
  const clean = (v: unknown, max: number) => typeof v === 'string' && v.length <= max ? v.trim() : '';
  const now = iso();
  const events = list.flatMap(item => {
    const e = item as Record<string, unknown>;
    const at = Date.parse(clean(e.date, 40));
    const title = clean(e.title, 120), country = clean(e.country, 8);
    return title && country && Number.isFinite(at) ? [{ id: `${country}|${title}|${clean(e.date, 40).slice(0, 10)}`, country, title, at: iso(at), impact: clean(e.impact, 20), forecast: clean(e.forecast, 30), previous: clean(e.previous, 30) }] : [];
  });
  for (let i = 0; i < events.length; i += 50) {
    await env.DB.batch(events.slice(i, i + 50).map(e => env.DB.prepare("INSERT INTO econ_events (id, country, title, at, impact, forecast, previous, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET at = excluded.at, impact = excluded.impact, forecast = CASE WHEN excluded.forecast = '' THEN econ_events.forecast ELSE excluded.forecast END, previous = excluded.previous, updated_at = excluded.updated_at")
      .bind(e.id, e.country, e.title, e.at, e.impact, e.forecast, e.previous, now)));
  }
  return Response.json({ stored: events.length }, { status: 201 });
}

interface Measure { series: string; transform: 'mom' | 'yoy' | 'level' | 'diff' | 'thousands'; lag: number; unit: '%' | 'K' | 'M'; places: number; surprise: number }
const measures: [RegExp, Measure][] = [
  [/^CPI m\/m$/, { series: 'CPIAUCSL', transform: 'mom', lag: 1, unit: '%', places: 1, surprise: 0.2 }],
  [/^Core CPI m\/m$/, { series: 'CPILFESL', transform: 'mom', lag: 1, unit: '%', places: 1, surprise: 0.2 }],
  [/^CPI y\/y$/, { series: 'CPIAUCNS', transform: 'yoy', lag: 1, unit: '%', places: 1, surprise: 0.2 }],
  [/^Non-Farm Employment Change$/, { series: 'PAYEMS', transform: 'diff', lag: 1, unit: 'K', places: 0, surprise: 75 }],
  [/^Unemployment Rate$/, { series: 'UNRATE', transform: 'level', lag: 1, unit: '%', places: 1, surprise: 0.2 }],
  [/^Average Hourly Earnings m\/m$/, { series: 'CES0500000003', transform: 'mom', lag: 1, unit: '%', places: 1, surprise: 0.2 }],
  [/^Core PCE Price Index m\/m$/, { series: 'PCEPILFE', transform: 'mom', lag: 1, unit: '%', places: 1, surprise: 0.2 }],
  [/^PPI m\/m$/, { series: 'PPIFIS', transform: 'mom', lag: 1, unit: '%', places: 1, surprise: 0.3 }],
  [/^Retail Sales m\/m$/, { series: 'RSAFS', transform: 'mom', lag: 1, unit: '%', places: 1, surprise: 0.5 }],
  [/^JOLTS Job Openings$/, { series: 'JTSJOL', transform: 'thousands', lag: 2, unit: 'M', places: 2, surprise: 0.4 }],
  [/^Unemployment Claims$/, { series: 'ICSA', transform: 'thousands', lag: 0, unit: 'K', places: 0, surprise: 20 }],
  [/^(Advance|Prelim|Final) GDP q\/q$/, { series: 'A191RL1Q225SBEA', transform: 'level', lag: 3, unit: '%', places: 1, surprise: 0.7 }],
];
export function measureFor(country: string, title: string): Measure | undefined {
  return country === 'USD' ? measures.find(([pattern]) => pattern.test(title))?.[1] : undefined;
}
export function parseFigure(value: string): number | undefined {
  const match = /^([+-]?(?:\d+(?:\.\d+)?|\.\d+))\s*([KMB%]?)$/i.exec(value.trim().replace(/,/g, '').replace(/−/g, '-'));
  return match && Number.isFinite(Number(match[1])) ? Number(match[1]) : undefined;
}

interface Actual { value: number; text: string; surprise?: number; big: boolean; period: string }
async function actual(event: EconEvent, env: DataEnv): Promise<Actual | undefined> {
  const measure = measureFor(event.country, event.title);
  if (!measure || Date.parse(event.at) > Date.now()) return undefined;
  const data = await fred(measure.series, env, ymd(Date.now() - 800 * day)).catch(() => null);
  return data ? actualFrom(event, measure, data.observations) : undefined;
}
export function actualFrom(event: { at: string; forecast: string }, measure: Measure, points: Observation[]): Actual | undefined {
  const released = new Date(event.at);
  let index = -1;
  if (measure.series === 'ICSA') {
    for (let i = points.length - 1; i >= 0 && index < 0; i--) {
      const gap = (released.getTime() - Date.parse(`${points[i].date}T12:00:00Z`)) / day;
      if (gap >= 3 && gap <= 9) index = i;
    }
  } else if (measure.series === 'A191RL1Q225SBEA') {
    const quarterStart = new Date(Date.UTC(released.getUTCFullYear(), Math.floor(released.getUTCMonth() / 3) * 3 - 3, 1));
    index = points.findIndex(p => p.date === ymd(quarterStart.getTime()));
  } else {
    const target = new Date(Date.UTC(released.getUTCFullYear(), released.getUTCMonth() - measure.lag, 1));
    index = points.findIndex(p => p.date === ymd(target.getTime()));
  }
  if (index < 0) return undefined;
  const point = points[index];
  let value: number;
  switch (measure.transform) {
    case 'mom': if (index < 1 || points[index - 1].value === 0 || points[index - 1].date !== ymd(Date.UTC(released.getUTCFullYear(), released.getUTCMonth() - measure.lag - 1, 1))) return undefined; value = (point.value / points[index - 1].value - 1) * 100; break;
    case 'yoy': { const base = points.find(p => p.date === `${Number(point.date.slice(0, 4)) - 1}${point.date.slice(4)}`); if (!base || base.value === 0) return undefined; value = (point.value / base.value - 1) * 100; break; }
    case 'diff': if (index < 1 || points[index - 1].date !== ymd(Date.UTC(released.getUTCFullYear(), released.getUTCMonth() - measure.lag - 1, 1))) return undefined; value = point.value - points[index - 1].value; break;
    case 'thousands': value = point.value / 1000; break;
    default: value = point.value;
  }
  value = round(value, measure.places);
  const suffix = /([KMB%])$/i.exec(event.forecast.trim())?.[1]?.toUpperCase();
  const rawForecast = parseFigure(event.forecast);
  const scales: Record<string, number> = { K: 1e3, M: 1e6, B: 1e9 };
  const forecast = rawForecast === undefined || (suffix === '%' && measure.unit !== '%') || (suffix && suffix !== '%' && measure.unit === '%') ? undefined : rawForecast * (suffix && scales[suffix] && scales[measure.unit] ? scales[suffix] / scales[measure.unit] : 1);
  const surprise = forecast === undefined ? undefined : round(value - forecast, Math.max(measure.places, 1));
  return { value, text: `${fmt(value, measure.places)}${measure.unit}`, surprise, big: surprise !== undefined && Math.abs(surprise) >= measure.surprise, period: point.date };
}
function eventRow(e: EconEvent, a?: Actual): Row {
  const time = new Date(e.at).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York' });
  const parts = [e.impact === 'High' ? 'High impact' : e.impact === 'Medium' ? 'Medium impact' : e.impact, e.forecast && `Forecast ${e.forecast}`, e.previous && `Previous ${e.previous}`].filter(Boolean);
  const surprise = a?.surprise === undefined ? undefined : a.surprise === 0 ? 'In line with forecast' : `${a.surprise > 0 ? 'Above' : 'Below'} forecast by ${fmt(Math.abs(a.surprise), 2).replace(/\.?0+$/, '')}`;
  return { label: `${e.country} ${e.title}`, value: a ? a.text : Date.parse(e.at) <= Date.now() ? 'Actual unavailable' : time, detail: parts.join(' · '), change_label: a ? surprise ?? `Released ${time}` : undefined, date: e.at,
    forecast: e.forecast || undefined, previous: e.previous || undefined, actual: a?.text, surprise: a?.surprise, series: measureFor(e.country, e.title)?.series };
}


export async function storePublicSources(value: unknown, env: DataEnv): Promise<Response> {
  const input = value as { rows?: Row[] } | null;
  if (!input || !Array.isArray(input.rows) || !input.rows.length || input.rows.length > 200 || input.rows.some(row => !row || typeof row.label !== 'string' || row.label.length > 500 || typeof row.url !== 'string' || !row.url.startsWith('https://news.google.com/') || typeof row.value !== 'string' || row.value.length > 200 || (row.detail !== undefined && (typeof row.detail !== 'string' || row.detail.length > 600)) || (row.date !== undefined && !Number.isFinite(Date.parse(row.date))))) throw new DataError(400, 'Invalid public source snapshot');
  const rows = input.rows.map(row => ({ label: row.label, value: row.value, url: row.url, date: row.date, detail: row.detail }));
  await env.DB.prepare('INSERT INTO public_sources (id, payload, updated_at) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at').bind(JSON.stringify(rows), iso()).run();
  return Response.json({ stored: rows.length }, { status: 201 });
}

export async function storeEconSeries(value: unknown, env: DataEnv): Promise<Response> {
  const input = value as { id?: string; observations?: Observation[] } | null;
  if (!input || !economicSeriesIDs.includes(input.id ?? '') || !Array.isArray(input.observations) || !input.observations.length || input.observations.length > 2500 || input.observations.some(o => !o || typeof o.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(o.date) || !Number.isFinite(Date.parse(o.date)) || ymd(Date.parse(o.date)) !== o.date || o.date > ymd() || typeof o.value !== 'number' || !Number.isFinite(o.value))) throw new DataError(400, 'Invalid economic series snapshot');
  const id = input.id!, spec = specs.get(id);
  const data: SeriesData = { id, title: spec?.label.replace(/, (?:y\/y|monthly change)$/, '') ?? id, units: spec?.transform === 'yoy' ? '' : spec?.unit ?? '', frequency: '', updated: '', observations: input.observations.sort((a, b) => a.date.localeCompare(b.date)) };
  await env.DB.prepare('INSERT INTO econ_series (id, payload, updated_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at').bind(id, JSON.stringify(data), iso()).run();
  return Response.json({ stored: data.observations.length }, { status: 201 });
}

export async function storeEconHistory(value: unknown, env: DataEnv): Promise<Response> {
  const input = value as { date?: unknown; rows?: unknown } | null;
  if (!input || typeof input.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(input.date) || !Number.isFinite(Date.parse(input.date)) || ymd(Date.parse(input.date)) !== input.date || input.date > ymd() || !Array.isArray(input.rows) || input.rows.length > 300) throw new DataError(400, 'Invalid historical calendar');
  const rows: Row[] = input.rows.map(raw => {
    if (!raw || typeof raw !== 'object') throw new DataError(400, 'Invalid historical row');
    const row = raw as Record<string, unknown>;
    const field = (key: string, max: number, required = false) => { if (row[key] !== undefined && typeof row[key] !== 'string') throw new DataError(400, `Invalid ${key}`); return text(row[key] as string | undefined, key, max, required); };
    const label = field('label', 180, true), actual = field('actual', 40), forecast = field('forecast', 40), previous = field('previous', 40);
    return { label, value: actual || 'Actual unavailable', actual: actual || undefined, forecast: forecast || undefined, previous: previous || undefined, date: input.date as string,
      detail: [forecast && `Forecast ${forecast}`, previous && `Previous ${previous}`, field('detail', 200)].filter(Boolean).join(' · '), url: 'https://www.nasdaq.com/market-activity/economic-calendar' };
  });
  await env.DB.prepare('INSERT INTO econ_history (date, payload, updated_at) VALUES (?, ?, ?) ON CONFLICT(date) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at').bind(input.date, JSON.stringify(rows), iso()).run();
  return Response.json({ stored: rows.length }, { status: 201 });
}

async function archivedReleases(env: DataEnv, days: number, countries: string[] = []): Promise<{ rows: Row[]; note: string }> {
  const { results } = await env.DB.prepare('SELECT date, payload, updated_at FROM econ_history WHERE date >= ? AND date <= ? ORDER BY date DESC').bind(ymd(Date.now() - days * day), ymd()).all<{ date: string; payload: string; updated_at: string }>();
  const rows = results.flatMap(record => (JSON.parse(record.payload) as Row[]).filter(row => (!countries.length || countries.includes(row.label.split(' ')[0])) && !!row.actual));
  return { rows, note: results.length ? `Archive covers ${results.length} calendar days; last sync ${results.map(r => r.updated_at).sort().at(-1)}.` : 'Historical calendar has not synced. Consensus coverage is incomplete.' };
}

// Fed funds futures

const monthCodes = 'FGHJKMNQUVXZ';
async function fomcMeetings(): Promise<string[]> {
  return cached('fomc/v1', 86400, async () => {
    const html = await getText('https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm', { headers: { 'User-Agent': 'Mozilla/5.0' } });
    return meetingDates(html);
  });
}
export function meetingDates(html: string): string[] {
  const months = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
  const dates: string[] = [];
  const years = [...html.matchAll(/(\d{4}) FOMC Meetings/g)];
  years.forEach((match, index) => {
    const segment = html.slice(match.index!, years[index + 1]?.index ?? html.length);
    for (const meeting of segment.matchAll(/fomc-meeting__month[^>]*>\s*<strong>([^<]+)<\/strong>[\s\S]*?fomc-meeting__date[^>]*>([^<]+)</g)) {
      if (/notation|unscheduled/i.test(meeting[2])) continue;
      const names = meeting[1].toLowerCase().split('/');
      const days = meeting[2].replace(/[^\d-]/g, '').split('-').filter(Boolean);
      const name = names.at(-1)!.trim();
      const month = months.findIndex(m => m.startsWith(name.slice(0, 3)));
      const last = Number(days.at(-1));
      if (month >= 0 && last) dates.push(`${match[1]}-${String(month + 1).padStart(2, '0')}-${String(last).padStart(2, '0')}`);
    }
  });
  return [...new Set(dates)].sort();
}

export function fedPath(current: number, meetings: string[], averages: Map<string, number>) {
  const result: { date: string; rate: number; move: number; cumulative: number }[] = [];
  let rate = current;
  for (const meeting of meetings) {
    const [y, m, d] = meeting.split('-').map(Number);
    const key = `${y}-${String(m).padStart(2, '0')}`;
    const average = averages.get(key);
    if (average === undefined) break;
    const days = new Date(Date.UTC(y, m, 0)).getUTCDate();
    const nextKey = m === 12 ? `${y + 1}-01` : `${y}-${String(m + 1).padStart(2, '0')}`;
    const nextHasMeeting = meetings.some(other => other.startsWith(nextKey));
    const share = d / days;
    const after = share > 0.7 && averages.has(nextKey) && !nextHasMeeting ? averages.get(nextKey)! : (average - share * rate) / (1 - share);
    result.push({ date: meeting, rate: round(after, 3), move: round((after - rate) * 100, 1), cumulative: round((after - current) * 100, 1) });
    rate = after;
  }
  return result;
}

export const shipAreas: Record<string, { name: string; portwatch: string; center: [number, number]; span: number; box: [[number, number], [number, number]] }> = {
  hormuz: { name: 'the Strait of Hormuz', portwatch: 'Strait of Hormuz', center: [26.4, 56.4], span: 2.4, box: [[25.0, 54.8], [27.6, 58.0]] },
  'bab-el-mandeb': { name: 'Bab el-Mandeb', portwatch: 'Bab el-Mandeb Strait', center: [12.7, 43.4], span: 2.4, box: [[11.4, 42.3], [14.0, 44.6]] },
  suez: { name: 'the Suez Canal', portwatch: 'Suez Canal', center: [30.4, 32.4], span: 2.2, box: [[29.3, 32.0], [31.6, 33.0]] },
  malacca: { name: 'the Strait of Malacca', portwatch: 'Malacca Strait', center: [2.5, 101.5], span: 4.5, box: [[0.5, 99.0], [4.8, 104.3]] },
  panama: { name: 'the Panama Canal', portwatch: 'Panama Canal', center: [9.1, -79.7], span: 1.2, box: [[8.6, -80.2], [9.6, -79.3]] },
  bosporus: { name: 'the Bosporus', portwatch: 'Bosporus Strait', center: [41.1, 29.05], span: 0.6, box: [[40.8, 28.8], [41.4, 29.3]] },
  taiwan: { name: 'the Taiwan Strait', portwatch: 'Taiwan Strait', center: [24.4, 119.6], span: 3.5, box: [[22.5, 117.8], [26.3, 121.4]] },
  gibraltar: { name: 'the Strait of Gibraltar', portwatch: 'Gibraltar Strait', center: [36.0, -5.6], span: 1.2, box: [[35.6, -6.3], [36.4, -4.9]] },
};

const portWatch = async () => {
  const since = ymd(Date.now() - 45 * day);
  const data = await cached(`portwatch/v1/${since}`, 21600, () => getJSON<{ features?: { attributes: Record<string, string | number> }[] }>(
    `https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services/Daily_Chokepoints_Data/FeatureServer/0/query?where=${encodeURIComponent(`date >= DATE '${since}'`)}&outFields=date,portname,n_total,n_tanker,n_container,n_dry_bulk&orderByFields=date%20DESC&resultRecordCount=2000&f=json`, { timeout: 15000 }));
  return (data.features ?? []).map(f => f.attributes);
};

// Tools

export const economicSeriesIDs = [...new Set([...specs.keys(), ...measures.map(([, m]) => m.series)])];

const tools: Tool[] = [
  {
    name: 'economic_history', path: 'economic/history', description: 'Archived economic releases with provider-reported actual, consensus and previous, including the latest monthly jobs and inflation reports. Use when releases lacks a report; default 60 days. Some Nasdaq duplicate labels omit frequency: do not guess monthly versus yearly. Filter by keywords and country.',
    params: { q: { type: 'string', description: 'Optional event keywords, such as payrolls, CPI, PCE or unemployment' }, days: { type: 'number', description: 'Days back, default 60, maximum 90' }, countries: { type: 'string', description: 'Optional comma-separated currency codes' } },
    async run(args, env) {
      const days = number(args.days, 'days', 1, 90, 60);
      const q = text(args.q, 'q', 100).toLowerCase();
      const countries = text(args.countries, 'countries', 60).toUpperCase().split(/[,\s]+/).filter(Boolean);
      const archive = await archivedReleases(env, days, countries);
      const rows = archive.rows.filter(row => !q || q.split(/\s+/).every(word => row.label.toLowerCase().includes(word)));
      return { title: 'Historical economic releases', source: 'Nasdaq economic calendar', url: 'https://www.nasdaq.com/market-activity/economic-calendar', note: `${archive.note} Provider omits frequency for some duplicate labels; verify the measure before naming it m/m or y/y.`, sections: [{ title: `Last ${days} days`, rows: rows.slice(0, 100) }] };
    },
  },
  {
    name: 'source_search', path: 'sources/search', description: 'Search recently collected public economic and macro news coverage for missing consensus forecasts and release context. This is not a general web search or stock/company news search; use stock_news for public company headlines. Returns headlines, dates, publisher links and excerpts; snippets are discovery evidence and may be incomplete. Prefer official series for actuals.',
    params: { q: { type: 'string', description: 'Specific search including indicator, month/year and forecast or consensus', required: true } },
    async run(args, env) {
      const q = text(args.q, 'q', 200, true);
      const saved = await env.DB.prepare('SELECT payload, updated_at FROM public_sources WHERE id = 1').first<{ payload: string; updated_at: string }>();
      if (!saved || Date.now() - Date.parse(saved.updated_at) > 2 * day) throw new DataError(503, 'Public coverage has not synced recently. Use wire_search or economic_history.');
      const terms = q.toLowerCase().split(/[^a-z0-9]+/).filter(word => word.length > 2 && !['the', 'and', 'for', 'latest', 'forecast', 'forecasts', 'consensus', 'data', 'united', 'states', '2026'].includes(word));
      const ranked = (JSON.parse(saved.payload) as Row[]).map(row => ({ row, score: terms.reduce((n, word) => n + Number(`${row.label} ${row.detail}`.toLowerCase().includes(word)), 0) })).filter(item => !terms.length || item.score > 0).sort((a, b) => b.score - a.score || (b.row.date ?? '').localeCompare(a.row.date ?? ''));
      return { title: `Public coverage: ${q}`, source: 'Google News RSS / linked publishers', url: `https://news.google.com/search?q=${encodeURIComponent(q)}`, as_of: saved.updated_at,
        note: 'Search of recently collected public economic coverage; not an exhaustive web search. Headlines and excerpts may omit context. Do not infer a number or consensus absent from the result.', sections: [{ title: 'Coverage', rows: ranked.slice(0, 12).map(item => item.row) }] };
    },
  },
  {
    name: 'macro', path: 'macro', description: 'Latest US and global economic indicators from FRED: Fed policy rates, jobs, inflation, growth, Treasury rates and money supply, corporate credit spreads, global 10-year yields, producer prices. Each row links a FRED series id usable with the series tool.',
    params: { group: { type: 'string', description: 'Optional group', enum: catalog.map(g => g.key) } },
    async run(args, env) {
      const group = args.group ? pick(args.group, 'group', catalog.map(g => g.key), '') : '';
      const groups = catalog.filter(g => !group || g.key === group);
      const sections = await mapLimited(groups, async g => ({ title: g.title, rows: await mapLimited(g.items, item => latest(item, env)) }), 1);
      return { title: group ? groups[0].title : 'Economic dashboard', source: 'FRED, Federal Reserve Bank of St. Louis', url: 'https://fred.stlouisfed.org', sections };
    },
  },
  {
    name: 'series', path: 'series', description: 'One FRED economic data series by id (for example UNRATE, CPIAUCSL, DGS10, BAMLH0A0HYM2): latest value, recent changes and history. Use series_search to find ids.',
    params: { id: { type: 'string', description: 'FRED series id', required: true }, start: { type: 'string', description: 'Optional start date YYYY-MM-DD; default five years ago' },
      transform: { type: 'string', description: 'Optional: level, yoy (percent change from a year earlier) or diff (change from prior observation)', enum: ['level', 'yoy', 'diff'] } },
    async run(args, env) {
      const id = seriesID(args.id);
      const start = args.start ? text(args.start, 'start', 10) : ymd(Date.now() - 5 * 365 * day);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) throw new DataError(400, 'Invalid start');
      const spec = specs.get(id);
      const transform = args.transform ? pick(args.transform, 'transform', ['level', 'yoy', 'diff'], 'level') : spec?.transform ?? 'level';
      const data = await fred(id, env, transform === 'yoy' ? ymd(Date.parse(start) - 400 * day) : transform === 'diff' ? ymd(Date.parse(start) - 100 * day) : start);
      const values = transformed(data.observations, transform === 'level' ? undefined : transform as Spec['transform']).filter(o => o.date >= start);
      if (!values.length) throw new DataError(404, `No observations for ${id}`);
      const last = values.at(-1)!;
      const ago = (days: number) => before(values, Date.parse(last.date) - days * day);
      const unit = transform === 'yoy' ? '% y/y' : data.units;
      const rows: Row[] = [{ label: 'Latest', value: `${fmt(last.value, 3)}${unit ? ` ${unit}` : ''}`, date: last.date }];
      for (const [label, days] of [['Prior observation', 0], ['1 month earlier', 28], ['1 year earlier', 360], ['5 years earlier', 1820]] as const) {
        const point = days ? ago(days) : values.at(-2);
        if (point && point !== last) rows.push({ label, value: fmt(point.value, 3), date: point.date, change_label: `${signed(last.value - point.value, 3)} since` });
      }
      const range = values.map(o => o.value);
      rows.push({ label: 'Range in window', value: `${fmt(Math.min(...range), 3)} to ${fmt(Math.max(...range), 3)}` });
      return { title: `${data.title} (${id})`, source: 'FRED, Federal Reserve Bank of St. Louis', url: fredURL(id), note: [transform === 'level' ? 'Level observations' : `Transform: ${transform}`, data.frequency, data.updated && `updated ${data.updated}`].filter(Boolean).join(' · ') || undefined,
        sections: [{ title: 'Summary', rows }], chart: { label: data.title, unit, points: thin(values, 240).map(o => ({ x: o.date, value: round(o.value, 4) })) } };
    },
  },
  {
    name: 'series_search', path: 'series/search', description: 'Search FRED economic series by keyword (full catalog when API key configured; curated indicators otherwise) (for example "japan cpi", "housing starts", "eurozone unemployment") and return ids, titles, frequency and units.',
    params: { q: { type: 'string', description: 'Search words', required: true }, limit: { type: 'number', description: 'Maximum results, default 15' } },
    async run(args, env) {
      const q = text(args.q, 'q', 120, true);
      const limit = number(args.limit, 'limit', 1, 50, 15);
      if (!env.FRED_API_KEY) {
        const words = q.toLowerCase().split(/\s+/);
        const rows = [...specs.values()].filter(s => words.every(w => `${s.id} ${s.label}`.toLowerCase().includes(w))).slice(0, limit).map(s => ({ label: s.label, value: s.id, series: s.id }));
        return { title: `FRED series matching “${q}”`, source: 'FRED', url: `https://fred.stlouisfed.org/searchresults?st=${encodeURIComponent(q)}`, note: 'Full FRED search needs a FRED_API_KEY secret on the Worker; showing the curated list only. No matches here does not mean a series does not exist. Use a known series id with series, or source_search for public coverage.', sections: [{ title: 'Curated series', rows }] };
      }
      const data = await cached(`fred/search/v1/${encodeURIComponent(q.toLowerCase())}/${limit}`, 86400, () => getJSON<{ seriess?: { id: string; title: string; frequency_short: string; units_short: string; observation_end: string; popularity: number }[] }>(
        `https://api.stlouisfed.org/fred/series/search?search_text=${encodeURIComponent(q)}&api_key=${encodeURIComponent(env.FRED_API_KEY!)}&file_type=json&limit=${limit}&order_by=popularity&sort_order=desc`));
      const rows = (data.seriess ?? []).map(s => ({ label: s.title, value: s.id, series: s.id, detail: `${s.frequency_short} · ${s.units_short}`, date: s.observation_end }));
      return { title: `FRED series matching “${q}”`, source: 'FRED', url: `https://fred.stlouisfed.org/searchresults?st=${encodeURIComponent(q)}`, sections: [{ title: 'Results by popularity', rows }] };
    },
  },
  {
    name: 'calendar', path: 'calendar', description: 'Economic calendar for the US and other major economies: scheduled releases with time, impact, forecast (consensus) and previous value for this week, then BLS releases and FOMC decisions further out.',
    params: { days: { type: 'number', description: 'Days ahead, default 7, maximum 60' },
      countries: { type: 'string', description: 'Optional comma-separated currency codes: USD, EUR, GBP, JPY, CNY, CAD, AUD, NZD, CHF' },
      impact: { type: 'string', description: 'high, medium (default, includes high) or all', enum: ['high', 'medium', 'all'] },
      upcoming: { type: 'string', description: 'true to leave out events that have already happened today', enum: ['true', 'false'] } },
    async run(args, env) {
      const days = number(args.days, 'days', 1, 60, 7);
      const upcoming = pick(args.upcoming, 'upcoming', ['true', 'false'], 'false') === 'true';
      const impact = pick(args.impact, 'impact', ['high', 'medium', 'all'], 'medium');
      const countries = text(args.countries, 'countries', 60).toUpperCase().split(/[,\s]+/).filter(Boolean);
      const now = Date.now(), from = ymd(now), to = ymd(now + days * day);
      const [events, bls, fomc] = await Promise.all([
        econEvents(env),
        cached('bls/ics/v1', 21600, async () => blsEvents(await getText('https://www.bls.gov/schedule/news_release/bls.ics', { headers: { 'User-Agent': sec } }))).catch(() => [] as Row[]),
        fomcMeetings().catch(() => [] as string[]),
      ]);
      const weekEnd = events.length ? events.map(e => e.at).sort().at(-1)!.slice(0, 10) : from;
      const levels = impact === 'high' ? ['High'] : impact === 'medium' ? ['High', 'Medium'] : ['High', 'Medium', 'Low', 'Holiday'];
      const actuals = await mapLimited(events, e => actual(e, env));
      const rows: (Row & { sort: string })[] = [
        ...events.map((e, i) => ({ e, a: actuals[i] })).filter(({ e }) => (!upcoming || Date.parse(e.at) >= now) && e.at.slice(0, 10) >= from && e.at.slice(0, 10) <= to && levels.includes(e.impact) && (!countries.length || countries.includes(e.country)))
          .map(({ e, a }) => ({ ...eventRow(e, a), sort: e.at })),
        ...bls.filter(r => r.date! > weekEnd && r.date! >= from && r.date! <= to && (!countries.length || countries.includes('USD'))).map(r => ({ ...r, sort: `${r.date}T${r.value}` })),
        ...fomc.filter(d => d > weekEnd && d >= from && d <= to && (!countries.length || countries.includes('USD'))).map(d => ({ label: 'USD FOMC rate decision', value: '2:00 PM ET', date: d, detail: 'Federal Reserve', url: 'https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm', sort: `${d}T14` })),
      ].sort((a, b) => a.sort.localeCompare(b.sort));
      const byDay = new Map<string, Row[]>();
      for (const { sort, ...row } of rows) {
        const key = sort.slice(0, 10);
        byDay.set(key, [...(byDay.get(key) ?? []), { ...row, date: undefined }]);
      }
      return { title: 'Economic calendar', source: 'ForexFactory calendar, BLS, Federal Reserve, FRED', url: 'https://www.forexfactory.com/calendar',
        note: `Times are US Eastern. Forecasts are the published consensus; actuals for US releases are computed from FRED once the data posts.${events.length ? '' : " This week's global calendar has not synced yet."}`,
        sections: [...byDay].map(([date, list]) => ({ title: new Date(`${date}T12:00:00Z`).toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric', timeZone: 'UTC' }), rows: list })) };
    },
  },
  {
    name: 'releases', path: 'releases', description: 'Economic surprises: recent releases with actual versus forecast (consensus) and previous, prioritizing major US reports and usable comparisons. US actuals (CPI, payrolls, unemployment, wages, PCE, PPI, retail sales, JOLTS, jobless claims, GDP) come from FRED; other countries show forecast and previous.',
    params: { days: { type: 'number', description: 'Days back, default 45 (covers monthly jobs and CPI), maximum 90' }, countries: { type: 'string', description: 'Optional comma-separated currency codes, default all' },
      impact: { type: 'string', description: 'high (default), medium or all', enum: ['high', 'medium', 'all'] } },
    async run(args, env) {
      const days = number(args.days, 'days', 1, 90, 45);
      const impact = pick(args.impact, 'impact', ['high', 'medium', 'all'], 'high');
      const countries = text(args.countries, 'countries', 60).toUpperCase().split(/[,\s]+/).filter(Boolean);
      const levels = impact === 'high' ? ['High'] : impact === 'medium' ? ['High', 'Medium'] : ['High', 'Medium', 'Low'];
      const { results } = await env.DB.prepare('SELECT * FROM econ_events WHERE at >= ? AND at <= ? ORDER BY at DESC LIMIT 300').bind(iso(Date.now() - days * day), iso()).all<EconEvent>();
      const past = results.filter(e => levels.includes(e.impact) && (!countries.length || countries.includes(e.country)));
      const actuals = await mapLimited(past, e => actual(e, env));
      const rows: Row[] = past.map((e, i) => ({ ...eventRow(e, actuals[i]), date: e.at }));
      const archive = await archivedReleases(env, days, countries);
      rows.push(...archive.rows.filter(row => (impact !== 'high' || /CPI|PCE|PPI|Nonfarm Payrolls|Unemployment Rate|Hourly Earnings|Retail Sales|GDP(?!Now)|Job Openings|Initial Jobless Claims/i.test(row.label)) && !rows.some(existing => existing.label === row.label && existing.date?.slice(0, 10) === row.date?.slice(0, 10))));
      rows.sort((a, b) => Number(!!b.actual && !!b.forecast) - Number(!!a.actual && !!a.forecast) || Number(/USD.*(?:Payroll|CPI|PCE|Unemployment|Earnings|GDP)/i.test(b.label)) - Number(/USD.*(?:Payroll|CPI|PCE|Unemployment|Earnings|GDP)/i.test(a.label)) || (b.date ?? '').localeCompare(a.date ?? ''));
      return { title: 'Economic releases vs forecast', source: 'ForexFactory, Nasdaq economic calendar, FRED', url: 'https://www.forexfactory.com/calendar',
        note: `Surprise is actual minus forecast in the reported units. FRED values may include revisions; archive values are provider-reported. Rows with actual and consensus and major US reports come first. Nasdaq omits frequency on some duplicate event names: do not infer monthly versus yearly from the value. ${archive.note} If a requested report is absent, use economic_history and source_search; absence is not evidence that no release occurred.`, sections: [{ title: `Last ${days} days`, rows: rows.slice(0, 100) }] };
    },
  },
  {
    name: 'fed_odds', path: 'fed/odds', description: 'Market-implied Fed path from 30-day fed funds futures (like Bloomberg WIRP): implied rate after each upcoming FOMC meeting, the move priced for that meeting, and cumulative change from today.',
    params: {},
    async run(_args, env) {
      const now = new Date();
      const months = Array.from({ length: 14 }, (_, i) => new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + i, 1)));
      const [meetings, effr, upper, lower, prices] = await Promise.all([
        fomcMeetings(),
        fred('EFFR', env, ymd(Date.now() - 30 * day)).catch(() => null),
        fred('DFEDTARU', env, ymd(Date.now() - 30 * day)).catch(() => null),
        fred('DFEDTARL', env, ymd(Date.now() - 30 * day)).catch(() => null),
        Promise.all(months.map(async month => {
          const symbol = `ZQ${monthCodes[month.getUTCMonth()]}${String(month.getUTCFullYear()).slice(2)}.CBT`;
          return { key: iso(month.getTime()).slice(0, 7), symbol, quote: await quote(symbol) };
        })),
      ]);
      const averages = new Map(prices.filter(p => p.quote).map(p => [p.key, 100 - p.quote!.price]));
      const current = effr?.observations.at(-1)?.value;
      if (current === undefined || !averages.size) throw new DataError(502, 'Fed funds futures or EFFR unavailable');
      const path = fedPath(current, meetings.filter(m => m >= ymd()), averages);
      const target = upper && lower ? `${fmt(lower.observations.at(-1)!.value)}–${fmt(upper.observations.at(-1)!.value)}%` : 'unavailable';
      const rows = path.map(p => {
        const odds = Math.min(100, Math.abs(p.move) / 25 * 100);
        const direction = p.move < 0 ? 'cut' : 'hike';
        return { label: new Date(`${p.date}T12:00:00Z`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }), value: `${fmt(p.rate, 3)}%`,
          change_label: `${signed(p.move, 1)} bp at meeting, ${signed(p.cumulative, 1)} bp cumulative`, detail: Math.abs(p.move) < 1 ? 'No change priced' : `${Math.round(odds)}% of a 25 bp ${direction}${Math.abs(p.move) > 25 ? ' (more than one move priced)' : ''}` };
      });
      return { title: 'Fed rate expectations', source: 'CME fed funds futures via Yahoo Finance; EFFR from FRED; FOMC calendar', url: 'https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm',
        note: `Target range ${target}; effective rate ${fmt(current)}%. Futures are unofficial Yahoo quotes; odds are a simple 25 bp approximation, not CME FedWatch.`,
        sections: [{ title: 'Implied rate after each meeting', rows }], chart: { label: 'Implied policy rate', unit: '%', points: [{ x: ymd(), value: current }, ...path.map(p => ({ x: p.date, value: p.rate }))] } };
    },
  },
  {
    name: 'yield_curve', path: 'yields', description: 'Government yield curve: US Treasury daily par curve (with change over a month), the euro area AAA curve from the ECB, or Japanese government bond (JGB) yields from Japan\'s Ministry of Finance.',
    params: { region: { type: 'string', description: 'us, euro or japan; default us', enum: ['us', 'euro', 'japan'] } },
    async run(args) {
      const region = pick(args.region, 'region', ['us', 'euro', 'japan'], 'us');
      if (region === 'japan') {
        const lines = (await cached('mof/jgb/v1', 3600, () => getText('https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/jgbcme.csv', { headers: { 'User-Agent': 'Mozilla/5.0' } }))).trim().split(/\r?\n/);
        const headerIndex = lines.findIndex(line => line.startsWith('Date,'));
        if (headerIndex < 0) throw new DataError(502, 'Ministry of Finance file format changed');
        const header = lines[headerIndex].split(',');
        const data = lines.slice(headerIndex + 1).map(line => line.split(',')).filter(cells => /^\d{4}\/\d{1,2}\/\d{1,2}$/.test(cells[0]));
        const last = data.at(-1), first = data[0];
        if (!last || !first) throw new DataError(502, 'No JGB yields published yet this month');
        const date = (value: string) => value.split('/').map((part, i) => i ? part.padStart(2, '0') : part).join('-');
        const rows = header.slice(1).flatMap((tenor, i) => {
          const value = Number(last[i + 1]), start = Number(first[i + 1]);
          return Number.isFinite(value) && last[i + 1] !== '-' ? [{ label: tenor, value: `${fmt(value, 3)}%`, change_label: first !== last && Number.isFinite(start) ? `${signed((value - start) * 100, 1)} bp since ${date(first[0])}` : undefined }] : [];
        });
        return { title: 'Japan government bond yields', source: 'Ministry of Finance, Japan', url: 'https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/index.htm',
          note: 'Daily JGB benchmark yields, published after the Tokyo close.', sections: [{ title: `Yields, ${date(last[0])}`, rows }], chart: { label: 'JGB curve', unit: '%', points: rows.map(r => ({ x: r.label, value: parseFloat(r.value) })) } };
      }
      if (region === 'euro') {
        const tenors = ['3M', '6M', '1Y', '2Y', '3Y', '5Y', '7Y', '10Y', '15Y', '20Y', '30Y'];
        const csv = await cached('ecb/yc/v2', 3600, () => getText(`https://data-api.ecb.europa.eu/service/data/YC/B.U2.EUR.4F.G_N_A.SV_C_YM.${tenors.map(t => `SR_${t}`).join('%2B')}?lastNObservations=22&format=csvdata&detail=dataonly`));
        const lines = csv.trim().split(/\r?\n/);
        const cellsOf = (line: string) => line.split(',').map(cell => cell.trim().replace(/^"|"$/g, ''));
        const header = cellsOf(lines[0]);
        const [k, d, v] = ['DATA_TYPE_FM', 'TIME_PERIOD', 'OBS_VALUE'].map(name => header.indexOf(name));
        const series = new Map<string, Observation[]>();
        for (const line of lines.slice(1)) {
          const cells = cellsOf(line);
          const tenor = cells[k]?.replace('SR_', '');
          if (tenor && Number.isFinite(Number(cells[v]))) series.set(tenor, [...(series.get(tenor) ?? []), { date: cells[d], value: Number(cells[v]) }]);
        }
        if (!tenors.some(t => series.has(t))) throw new DataError(502, `ECB returned no yield data (${[...series.keys()].slice(0, 3).join(', ') || header.slice(0, 10).join(' ')})`);
        const rows = tenors.filter(t => series.has(t)).map(t => {
          const values = series.get(t)!.sort((a, b) => a.date.localeCompare(b.date));
          const last = values.at(-1)!, first = values[0];
          return { label: t, value: `${fmt(last.value, 3)}%`, change_label: `${signed((last.value - first.value) * 100, 1)} bp since ${first.date}` };
        });
        return { title: 'Euro area AAA government yield curve', source: 'European Central Bank', url: 'https://www.ecb.europa.eu/stats/financial_markets_and_interest_rates/euro_area_yield_curves/html/index.en.html',
          note: 'Svensson-model spot rates for AAA-rated euro area sovereigns.', sections: [{ title: `Spot rates, ${series.get('10Y')?.at(-1)?.date ?? ''}`, rows }], chart: { label: 'Spot curve', unit: '%', points: rows.map(r => ({ x: r.label, value: Number(r.value.replace('%', '')) })) } };
      }
      const year = new Date().getUTCFullYear();
      const load = (y: number) => cached(`treasury/yc/v1/${y}`, 3600, () => getText(`https://home.treasury.gov/resource-center/data-chart-center/interest-rates/daily-treasury-rates.csv/${y}/all?type=daily_treasury_yield_curve&field_tdr_date_value=${y}&page&_format=csv`, { headers: { 'User-Agent': 'Mozilla/5.0' } }));
      let lines = (await load(year)).trim().split('\n');
      if (lines.length < 23) lines = [...lines, ...(await load(year - 1)).trim().split('\n').slice(1)];
      const header = lines[0].split(',').map(h => h.replace(/"/g, ''));
      const rowsOf = (line: string) => line.split(',');
      const latestRow = rowsOf(lines[1]), monthAgo = rowsOf(lines[Math.min(22, lines.length - 1)]);
      const toIso = (value: string) => { const [m, d2, y] = value.split('/'); return `${y}-${m}-${d2}`; };
      const rows: Row[] = header.slice(1).flatMap((tenor, i) => {
        const value = Number(latestRow[i + 1]), before = Number(monthAgo[i + 1]);
        if (!latestRow[i + 1] || !Number.isFinite(value)) return [];
        return [{ label: tenor.replace('1.5 Month', '6W').replace(' Mo', 'M').replace(' Yr', 'Y'), value: `${fmt(value)}%`,
          change_label: Number.isFinite(before) && monthAgo[i + 1] ? `${signed((value - before) * 100, 0)} bp vs ${toIso(monthAgo[0])}` : undefined }];
      });
      const two = rows.find(r => r.label === '2Y'), ten = rows.find(r => r.label === '10Y'), three = rows.find(r => r.label === '3M');
      const spread = (a?: Row, b?: Row) => a && b ? `${signed((parseFloat(a.value) - parseFloat(b.value)) * 100, 0)} bp` : 'n/a';
      return { title: 'US Treasury yield curve', source: 'US Treasury daily par yield curve', url: 'https://home.treasury.gov/resource-center/data-chart-center/interest-rates/TextView?type=daily_treasury_yield_curve',
        note: `10Y–2Y ${spread(ten, two)}; 10Y–3M ${spread(ten, three)}.`, sections: [{ title: `Par yields, ${toIso(latestRow[0])}`, rows }],
        chart: { label: 'Par yield curve', unit: '%', points: rows.map(r => ({ x: r.label, value: parseFloat(r.value) })) } };
    },
  },
  {
    name: 'board', path: 'board', description: 'Live market boards: world equity indices (Bloomberg WEI), currencies (FXC), commodities including oil, gas, metals, steel and grains, or US rates and futures. Quotes are delayed and unofficial.',
    params: { name: { type: 'string', description: 'world, fx, commodities or rates', enum: Object.keys(boards), required: true } },
    async run(args) {
      const name = pick(args.name, 'name', Object.keys(boards), 'world');
      const board = boards[name];
      const sections = await Promise.all(board.sections.map(async s => ({ title: s.title, rows: await quoteRows(s.symbols) })));
      return { title: board.title, source: 'Yahoo Finance (unofficial, delayed)', url: 'https://finance.yahoo.com/markets/', sections };
    },
  },
  {
    name: 'quote', path: 'quote', description: 'Current quotes for up to 12 symbols, including non-US listings (7203.T Toyota, SHEL.L Shell, SAP.DE, 0700.HK Tencent, RY.TO), indices (^N225), currencies (EURUSD=X) and futures (CL=F). London prices are converted from pence.',
    params: { symbols: { type: 'string', description: 'Comma-separated Yahoo symbols', required: true } },
    async run(args) {
      const symbols = text(args.symbols, 'symbols', 200, true).split(',').map(s => s.trim().toUpperCase()).filter(Boolean);
      if (symbols.length > 12 || symbols.some(s => !/^[A-Z0-9^=.\-]{1,20}$/.test(s))) throw new DataError(400, 'Invalid symbols');
      const loaded = await Promise.all(symbols.map(async s => ({ s, q: await quote(s) })));
      const rows = loaded.map(({ s, q }) => q ? { ...quoteRow(q), detail: `${q.exchange} · ${q.state}` } : { label: s, symbol: s, value: 'unavailable' });
      return { title: 'Quotes', source: 'Yahoo Finance (unofficial, delayed)', url: 'https://finance.yahoo.com', sections: [{ title: 'Quotes', rows }] };
    },
  },
  {
    name: 'stock_history', path: 'stock/history', description: 'Historical daily share prices and percentage return for one stock, including year-to-date. Price return excludes dividends. Use this for questions such as why a stock is up this year; pair it with stock_news and stock_fundamentals to investigate possible catalysts.',
    params: {
      symbol: { type: 'string', description: 'Yahoo ticker, such as BB or BB.TO', required: true },
      period: { type: 'string', description: 'History window; default ytd', enum: ['1mo', '3mo', '6mo', 'ytd', '1y', '5y', 'max'] },
    },
    async run(args) {
      const symbol = text(args.symbol, 'symbol', 20, true).toUpperCase();
      if (!/^[A-Z0-9^=.-]{1,20}$/.test(symbol)) throw new DataError(400, 'Invalid symbol');
      const period = pick(args.period, 'period', ['1mo', '3mo', '6mo', 'ytd', '1y', '5y', 'max'], 'ytd');
      const intervals: Record<string, string> = { '1mo': '1d', '3mo': '1d', '6mo': '1d', ytd: '1d', '1y': '1d', '5y': '1wk', max: '1mo' };
      type ChartResult = {
        meta?: { symbol?: string; shortName?: string; longName?: string; currency?: string; regularMarketPrice?: number; regularMarketTime?: number; chartPreviousClose?: number };
        timestamp?: number[];
        indicators?: { quote?: { close?: (number | null)[] }[] };
      };
      const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=${period}&interval=${intervals[period]}`;
      const data = await cached(`yahoo/history/v1/${symbol}/${period}`, 300, () => getJSON<{ chart?: { result?: ChartResult[] } }>(url));
      const result = data.chart?.result?.[0], meta = result?.meta;
      if (!result || !meta) throw new DataError(404, `No price history for ${symbol}`);
      const closes = result.indicators?.quote?.[0]?.close ?? [];
      const points = (result.timestamp ?? []).flatMap((stamp, index) => {
        const value = closes[index];
        return typeof value === 'number' && Number.isFinite(value) ? [{ x: ymd(stamp * 1000), value: round(value, 4) }] : [];
      });
      const hasPriorClose = period === 'ytd' && meta.chartPreviousClose !== undefined;
      const reference = period === 'ytd' ? meta.chartPreviousClose ?? points[0]?.value : points[0]?.value;
      const latest = meta.regularMarketPrice ?? points.at(-1)?.value;
      if (reference === undefined || latest === undefined || reference <= 0 || !points.length) throw new DataError(404, `No usable price history for ${symbol}`);
      const difference = latest - reference;
      const returnPercent = difference / reference * 100;
      const currency = meta.currency ?? 'currency unavailable';
      const name = meta.longName ?? meta.shortName ?? symbol;
      const decimals = (value: number) => value >= 1000 ? 0 : value < 1 ? 4 : 2;
      const lastDate = meta.regularMarketTime ? ymd(meta.regularMarketTime * 1000) : points.at(-1)!.x;
      const referenceDetail = hasPriorClose ? 'Yahoo prior close before the year-to-date window' : `First available close in ${period}`;
      return {
        title: `${name} price history (${period.toUpperCase()})`, source: 'Yahoo Finance chart (unofficial)',
        url: `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}/history/`,
        as_of: meta.regularMarketTime ? iso(meta.regularMarketTime * 1000) : undefined,
        note: `Close-to-close price return; excludes dividends. ${period === 'ytd' ? hasPriorClose ? 'The YTD base uses Yahoo chartPreviousClose.' : 'Yahoo did not return chartPreviousClose; the first observed close is used as the base.' : 'The base is the first available close in the requested window.'}`,
        sections: [{ title: 'Performance', rows: [
          { label: `${period.toUpperCase()} price return`, value: signed(returnPercent, 1, '%'), detail: `${signed(difference, decimals(difference))} ${currency}` },
          { label: 'Reference close', value: `${fmt(reference, decimals(reference))} ${currency}`, detail: referenceDetail },
          { label: 'Latest price', value: `${fmt(latest, decimals(latest))} ${currency}`, date: lastDate },
        ] }],
        chart: { label: 'Daily closing price', unit: currency, points: thin(points, 36) },
      };
    },
  },
  {
    name: 'stock_fundamentals', path: 'stock/fundamentals', description: 'Company fundamentals and recent reported quarterly results for a stock: EPS actual versus estimate and surprise, quarterly revenue and net income, revenue/earnings growth, cash, debt, and market valuation. This feed does not contain management guidance; check filings and stock_news for guidance or explanation.',
    params: { symbol: { type: 'string', description: 'Yahoo ticker, such as BB or BB.TO', required: true } },
    async run(args) {
      const symbol = text(args.symbol, 'symbol', 20, true).toUpperCase();
      if (!/^[A-Z0-9^=.-]{1,20}$/.test(symbol)) throw new DataError(400, 'Invalid symbol');
      type SummaryResult = { quoteSummary?: { result?: Record<string, unknown>[] } };
      const modules = 'price,summaryDetail,defaultKeyStatistics,financialData,assetProfile,calendarEvents,earnings,earningsHistory';
      const data = await cached(`yahoo/fundamentals/v1/${symbol}`, 1800, () => yahooAuthed<SummaryResult>(`https://query2.finance.yahoo.com/v10/finance/quoteSummary/${encodeURIComponent(symbol)}?modules=${modules}`));
      const result = data.quoteSummary?.result?.[0];
      if (!result) throw new DataError(404, `No company fundamentals for ${symbol}`);
      const price = objectValue(result.price), summary = objectValue(result.summaryDetail), financial = objectValue(result.financialData);
      const profile = objectValue(result.assetProfile), earnings = objectValue(result.earnings), calendar = objectValue(objectValue(result.calendarEvents).earnings);
      const currency = String(financial.financialCurrency ?? price.currency ?? 'USD');
      const rows: Row[] = [];
      const add = (label: string, value: unknown, unit = '') => {
        const formatted = yahooFormatted(value);
        if (formatted) rows.push({ label, value: `${unit}${formatted}` });
      };
      add('Sector', profile.sector);
      add('Industry', profile.industry);
      add('Market capitalization', price.marketCap ?? summary.marketCap, `${currency} `);
      add('Trailing P/E', summary.trailingPE);
      add('Revenue growth', financial.revenueGrowth);
      add('Earnings growth', financial.earningsGrowth);
      add('Total revenue', financial.totalRevenue, `${currency} `);
      add('Cash', financial.totalCash, `${currency} `);
      add('Total debt', financial.totalDebt, `${currency} `);
      const nextDate = Array.isArray(calendar.earningsDate) ? yahooFormatted(calendar.earningsDate[0]) : undefined;
      add('Next earnings date', nextDate);

      const financeChart = objectValue(earnings.financialsChart);
      const quarterlyFinancials = (Array.isArray(financeChart.quarterly) ? financeChart.quarterly : []).map(objectValue);
      const byQuarter = new Map(quarterlyFinancials.flatMap(item => typeof item.date === 'string' ? [[item.date, item] as const] : []));
      const earningsChart = objectValue(earnings.earningsChart);
      const quarterlyEarnings = (Array.isArray(earningsChart.quarterly) ? earningsChart.quarterly : []).map(objectValue);
      const results = quarterlyEarnings.slice(-4).flatMap(item => {
        const actual = yahooRaw(item.actual), estimate = yahooRaw(item.estimate);
        if (actual === undefined) return [];
        const period = String(item.fiscalQuarter ?? item.date ?? 'Quarter');
        const detail = [
          typeof item.surprisePct === 'string' ? `EPS surprise ${item.surprisePct.replace(/%$/, '')}%` : undefined,
          yahooFormatted(byQuarter.get(String(item.date))?.revenue) ? `revenue ${currency} ${yahooFormatted(byQuarter.get(String(item.date))?.revenue)}` : undefined,
          yahooFormatted(byQuarter.get(String(item.date))?.earnings) ? `net income ${currency} ${yahooFormatted(byQuarter.get(String(item.date))?.earnings)}` : undefined,
        ].filter(Boolean).join(' · ');
        return [{ label: period, value: `EPS actual ${actual.toFixed(2)} ${currency}${estimate === undefined ? '' : ` vs estimate ${estimate.toFixed(2)} ${currency}`}`,
          date: yahooFormatted(item.reportedDate), detail: detail || undefined }];
      });
      const annualFinancials = (Array.isArray(financeChart.yearly) ? financeChart.yearly : []).map(objectValue).slice(-4).flatMap(item => {
        if (item.date === undefined) return [];
        const revenue = yahooFormatted(item.revenue), netIncome = yahooFormatted(item.earnings);
        return [{ label: String(item.date), value: revenue ? `Revenue ${currency} ${revenue}` : 'Revenue unavailable',
          detail: [netIncome && `net income ${currency} ${netIncome}`, yahooFormatted(item.profitMargin) && `margin ${yahooFormatted(item.profitMargin)}`].filter(Boolean).join(' · ') || undefined }];
      });
      if (!rows.length && !results.length && !annualFinancials.length) throw new DataError(404, `No usable fundamentals for ${symbol}`);
      return {
        title: `${String(price.longName ?? price.shortName ?? symbol)} fundamentals`, source: 'Yahoo Finance (unofficial)',
        url: `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}/`,
        note: 'Yahoo provider-normalized estimates and results may lag filings. This feed does not provide management guidance; missing values do not mean the company gave no guidance.',
        sections: [
          ...(rows.length ? [{ title: 'Company and current fundamentals', rows }] : []),
          ...(results.length ? [{ title: 'Recent reported quarters', rows: results }] : []),
          ...(annualFinancials.length ? [{ title: 'Annual financials', rows: annualFinancials }] : []),
        ],
      };
    },
  },
  {
    name: 'stock_news', path: 'stock/news', description: 'Recent public news headlines for a listed company. Results must name the company or contain its exact ticker in the headline; Yahoo related-ticker tags alone are too noisy. Use headlines as leads, then verify important claims against company filings or the linked article. Headlines alone do not prove what caused a stock move.',
    params: {
      symbol: { type: 'string', description: 'Yahoo ticker, such as BB or BB.TO', required: true },
      company: { type: 'string', description: 'Company name to improve matching, for example BlackBerry' },
      days: { type: 'number', description: 'Look-back window in days, default 180, maximum 730' },
      limit: { type: 'number', description: 'Maximum headlines, default 12' },
    },
    async run(args) {
      const symbol = text(args.symbol, 'symbol', 20, true).toUpperCase();
      if (!/^[A-Z0-9^=.-]{1,20}$/.test(symbol)) throw new DataError(400, 'Invalid symbol');
      const company = text(args.company, 'company', 100);
      const days = number(args.days, 'days', 1, 730, 180), limit = number(args.limit, 'limit', 1, 20, 12);
      type NewsItem = { title?: string; publisher?: string; link?: string; providerPublishTime?: number; relatedTickers?: string[] };
      const queries = [...new Set([symbol, company].filter(Boolean))];
      const feeds = await Promise.all(queries.map(query => cached(`yahoo/stock-news/v1/${encodeURIComponent(query.toLowerCase())}`, 600, () =>
        getJSON<{ news?: NewsItem[] }>(`https://query1.finance.yahoo.com/v1/finance/search?q=${encodeURIComponent(query)}&quotesCount=0&newsCount=20&listsCount=0`))));
      const cutoff = Date.now() - days * day;
      const seen = new Set<string>();
      const tickerInTitle = (title: string) => {
        const upperTitle = title.toUpperCase();
        let index = upperTitle.indexOf(symbol);
        while (index >= 0) {
          const before = upperTitle[index - 1] ?? '';
          const after = upperTitle[index + symbol.length] ?? '';
          if ((!before || !/[A-Z0-9]/.test(before)) && (!after || !/[A-Z0-9]/.test(after))) return true;
          index = upperTitle.indexOf(symbol, index + 1);
        }
        return false;
      };
      const rows = feeds.flatMap(feed => feed.news ?? []).flatMap(item => {
        if (!item.title || !item.link || !item.providerPublishTime) return [];
        const published = item.providerPublishTime * 1000;
        const related = item.relatedTickers ?? [];
        const companyMatch = company.length > 1 && item.title.toLowerCase().includes(company.toLowerCase());
        if (published < cutoff || published > Date.now() + 300000 || (!companyMatch && !tickerInTitle(item.title))) return [];
        let url: URL;
        try { url = new URL(item.link); } catch { return []; }
        if (url.protocol !== 'https:' || seen.has(url.href)) return [];
        seen.add(url.href);
        return [{ label: item.title, value: item.publisher ?? url.hostname, date: iso(published), url: url.href,
          detail: related.length ? `Related tickers: ${[...new Set(related)].join(', ')}` : undefined }];
      }).sort((a, b) => b.date!.localeCompare(a.date!)).slice(0, limit);
      return {
        title: `${company || symbol} public news`, source: 'Yahoo Finance news search (unofficial)',
        url: `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}/news/`,
        note: rows.length ? `Latest ${rows.length} headlines whose title names the company or includes the exact ticker, from the last ${days} days. Yahoo related-ticker tags alone are excluded because they can match unrelated stories. Search coverage is not exhaustive; headlines suggest leads, not proven causes.` : `No direct company-name or exact-ticker headlines returned for the last ${days} days. An empty search is not proof that no catalyst occurred.`,
        sections: [{ title: 'Public headlines', rows }],
      };
    },
  },
  {
    name: 'symbol_search', path: 'symbols', description: 'Find ticker symbols worldwide by company name, grouped by company so every listing (for example Toyota: TM in New York and 7203.T in Tokyo) appears together with its exchange.',
    params: { q: { type: 'string', description: 'Company or ticker', required: true } },
    async run(args) {
      const q = text(args.q, 'q', 80, true);
      const data = await cached(`symbols/v1/${encodeURIComponent(q.toLowerCase())}`, 86400, () => getJSON<{ quotes?: { symbol: string; shortname?: string; longname?: string; quoteType?: string; exchDisp?: string }[] }>(
        `https://query2.finance.yahoo.com/v1/finance/search?q=${encodeURIComponent(q)}&quotesCount=20&newsCount=0&listsCount=0&enableFuzzyQuery=false`));
      const groups = new Map<string, Row[]>();
      for (const item of data.quotes ?? []) {
        if (!item.symbol) continue;
        const name = item.longname ?? item.shortname ?? item.symbol;
        const key = companyKey(name);
        groups.set(key, [...(groups.get(key) ?? []), { label: name, symbol: item.symbol, value: item.symbol, detail: [item.quoteType?.toLowerCase(), item.exchDisp].filter(Boolean).join(' · ') }]);
      }
      return { title: `Listings matching “${q}”`, source: 'Yahoo Finance search', url: `https://finance.yahoo.com/lookup?s=${encodeURIComponent(q)}`, sections: [...groups.values()].map(rows => ({ title: rows[0].label, rows })) };
    },
  },
  {
    name: 'screener', path: 'screener', description: 'Screen stocks worldwide with filters: region (us, jp, gb, de, fr, hk, ca, in, kr, au, ch, nl, it, es, se, tw, br), sector, maximum trailing P/E, minimum market cap in billions of US dollars, minimum dividend yield. Example: cheap European banks = region de/fr/it/es, sector Financial Services, max_pe 10.',
    params: {
      region: { type: 'string', description: 'Two-letter market code; default us' },
      sector: { type: 'string', description: 'Optional sector', enum: ['Technology', 'Financial Services', 'Healthcare', 'Consumer Cyclical', 'Consumer Defensive', 'Industrials', 'Energy', 'Basic Materials', 'Utilities', 'Real Estate', 'Communication Services'] },
      max_pe: { type: 'number', description: 'Maximum trailing P/E; 0 for none' },
      min_market_cap: { type: 'number', description: 'Minimum market cap in billions USD; default 1' },
      min_dividend_yield: { type: 'number', description: 'Minimum dividend yield percent; 0 for none' },
      sort: { type: 'string', description: 'marketcap (default), pe, dividend or change', enum: ['marketcap', 'pe', 'dividend', 'change'] },
      limit: { type: 'number', description: 'Maximum results, default 15, maximum 50' },
    },
    async run(args) {
      const regions = ['us', 'jp', 'gb', 'de', 'fr', 'hk', 'ca', 'in', 'kr', 'au', 'ch', 'nl', 'it', 'es', 'se', 'tw', 'br', 'cn', 'sg', 'dk', 'no', 'fi', 'be', 'mx', 'za', 'il'];
      const list = text(args.region, 'region', 60).toLowerCase().split(/[,\s]+/).filter(Boolean);
      const region = list.length ? list : ['us'];
      if (region.some(r => !regions.includes(r))) throw new DataError(400, `Invalid region; use ${regions.join(', ')}`);
      const sector = args.sector ? text(args.sector, 'sector', 40) : '';
      const maxPE = number(args.max_pe, 'max_pe', 0, 1000, 0), minCap = number(args.min_market_cap, 'min_market_cap', 0, 10000, 1), minYield = number(args.min_dividend_yield, 'min_dividend_yield', 0, 50, 0);
      const sort = pick(args.sort, 'sort', ['marketcap', 'pe', 'dividend', 'change'], 'marketcap');
      const limit = number(args.limit, 'limit', 1, 50, 15);
      const operands: unknown[] = [
        region.length === 1 ? { operator: 'eq', operands: ['region', region[0]] } : { operator: 'or', operands: region.map(r => ({ operator: 'eq', operands: ['region', r] })) },
        { operator: 'gt', operands: ['intradaymarketcap', minCap * 1e9] },
      ];
      if (sector) operands.push({ operator: 'eq', operands: ['sector', sector] });
      if (maxPE) operands.push({ operator: 'btwn', operands: ['peratio.lasttwelvemonths', 0, maxPE] });
      if (minYield) operands.push({ operator: 'gt', operands: ['forward_dividend_yield', minYield] });
      const sortField = { marketcap: 'intradaymarketcap', pe: 'peratio.lasttwelvemonths', dividend: 'forward_dividend_yield', change: 'percentchange' }[sort];
      const body = { size: 100, offset: 0, sortField, sortType: sort === 'pe' ? 'ASC' : 'DESC', quoteType: 'EQUITY', query: { operator: 'and', operands }, userId: '', userIdType: 'guid' };
      const data = await yahooAuthed<{ finance?: { result?: { total: number; quotes: Record<string, unknown>[] }[] } }>('https://query2.finance.yahoo.com/v1/finance/screener?formatted=false&lang=en-US&region=US',
        { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const result = data.finance?.result?.[0];
      const suffixes: Record<string, string[]> = { us: [''], jp: ['.T'], gb: ['.L'], de: ['.DE'], fr: ['.PA'], hk: ['.HK'], ca: ['.TO', '.V'], in: ['.NS', '.BO'], kr: ['.KS', '.KQ'], au: ['.AX'], ch: ['.SW'], nl: ['.AS'],
        it: ['.MI'], es: ['.MC'], se: ['.ST'], tw: ['.TW', '.TWO'], br: ['.SA'], cn: ['.SS', '.SZ'], sg: ['.SI'], dk: ['.CO'], no: ['.OL'], fi: ['.HE'], be: ['.BR'], mx: ['.MX'], za: ['.JO'], il: ['.TA'] };
      const seen = new Set<string>();
      const primary = (result?.quotes ?? []).filter(q => {
        const key = String(q.longName ?? q.shortName ?? q.symbol).toLowerCase();
        const suffix = /\.[A-Z]+$/.exec(String(q.symbol))?.[0] ?? '';
        if (!region.some(r => (suffixes[r] ?? [suffix]).includes(suffix)) || /^\d[A-Z]/.test(String(q.symbol)) || seen.has(key)) return false;
        seen.add(key);
        return true;
      }).slice(0, limit);
      const rows = primary.map(q => {
        const currency = String(q.currency ?? 'USD'), minor = minorCurrency(currency);
        const price = Number(q.regularMarketPrice) / (minor ? 100 : 1);
        const details = [q.trailingPE ? `P/E ${fmt(Number(q.trailingPE), 1)}` : '', q.marketCap ? `cap ${currency === 'USD' ? money(Number(q.marketCap)) : `${money(Number(q.marketCap)).replace('$', '')} ${minor ?? currency}`}` : '', q.dividendYield ? `yield ${fmt(Number(q.dividendYield), 2)}%` : '', String(q.fullExchangeName ?? '')].filter(Boolean);
        return { label: String(q.longName ?? q.shortName ?? q.symbol), symbol: String(q.symbol), value: `${fmt(price)} ${minor ?? currency}`, change: round(Number(q.regularMarketChangePercent ?? 0)), detail: details.join(' · ') };
      });
      return { title: 'Stock screen', source: 'Yahoo Finance screener (unofficial)', url: 'https://finance.yahoo.com/research-hub/screener/',
        note: `${result?.total ?? 0} matches · region ${region.join('/')}${sector ? ` · ${sector}` : ''}${maxPE ? ` · P/E ≤ ${maxPE}` : ''} · cap ≥ $${minCap}B${minYield ? ` · yield ≥ ${minYield}%` : ''}. Market caps are in each listing's currency; exchanges such as XETRA also list foreign companies.`, sections: [{ title: 'Results', rows }] };
    },
  },
  {
    name: 'wire_search', path: 'wire/search', description: 'Full-text search only of stories Newswire itself has published (titles, summaries and bodies), newest relevant first. This is not public-web search; use stock_news for public company headlines and source_search only for recently collected economic news.',
    params: { q: { type: 'string', description: 'Search words; all must match', required: true }, days: { type: 'number', description: 'Only stories from the last N days; default 30' }, limit: { type: 'number', description: 'Maximum results, default 15' } },
    async run(args, env) {
      const q = text(args.q, 'q', 200, true);
      const days = number(args.days, 'days', 1, 3650, 30), limit = number(args.limit, 'limit', 1, 50, 15);
      const match = ftsQuery(q);
      if (!match) throw new DataError(400, 'Invalid q');
      const { results } = await env.DB.prepare(`SELECT s.id, s.title, s.source, s.url, s.published_at, s.tickers, snippet(stories_fts, 2, '', '', '…', 24) AS excerpt FROM stories_fts JOIN stories s ON s.rowid = stories_fts.rowid
        WHERE stories_fts MATCH ? AND s.retracted_at IS NULL AND s.published_at >= ? ORDER BY bm25(stories_fts, 10.0, 4.0, 1.0) + (julianday('now') - julianday(s.published_at)) / 7.0 LIMIT ?`).bind(match, iso(Date.now() - days * day), limit).all<Record<string, string>>();
      const rows = results.map(r => ({ label: r.title, value: r.source, date: r.published_at, story: r.id, url: r.url, detail: [JSON.parse(r.tickers).join(' '), r.excerpt].filter(Boolean).join(' · ').slice(0, 300) }));
      return { title: `Wire stories matching “${q}”`, source: 'Newswire', url: 'https://bryce-newswire.bryce-e19.workers.dev', note: `${rows.length} stories from the last ${days} days.`, sections: [{ title: 'Stories', rows }] };
    },
  },
  {
    name: 'sec_filings', path: 'sec/filings', description: 'Recent SEC EDGAR filings for a US-listed company (10-K, 10-Q, 8-K, S-1, 13D/G, DEF 14A and more), optionally filtered by form type.',
    params: { symbol: { type: 'string', description: 'US ticker', required: true }, form: { type: 'string', description: 'Optional form type such as 8-K or 10-Q' }, limit: { type: 'number', description: 'Maximum results, default 15' } },
    async run(args) {
      const company = await cik(args.symbol);
      const form = text(args.form, 'form', 20).toUpperCase();
      const limit = number(args.limit, 'limit', 1, 50, 15);
      const recent = (await submissions(company.cik)).filings.recent;
      const rows: Row[] = [];
      for (let i = 0; i < recent.form.length && rows.length < limit; i++) {
        if (form && recent.form[i] !== form) continue;
        const description = recent.primaryDocDescription?.[i];
        rows.push({ label: description && description.toUpperCase() !== recent.form[i] ? `${recent.form[i]} · ${description}` : recent.form[i], value: recent.form[i], date: recent.filingDate[i], detail: recent.items?.[i] ? `Items ${recent.items[i]}` : undefined, url: filingURL(company.cik, recent.accessionNumber[i], recent.primaryDocument[i]) });
      }
      return { title: `${company.name} SEC filings${form ? ` (${form})` : ''}`, source: 'SEC EDGAR', url: `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${company.cik}`, sections: [{ title: 'Filings', rows }] };
    },
  },
  {
    name: 'institution_search', path: 'sec/institution-search', description: 'Search SEC EDGAR for institutional managers with recent Form 13F holdings reports. Results are discovered from SEC filer records rather than a fixed manager list.',
    params: { q: { type: 'string', description: 'Institution or manager name, such as Jane Street or Vanguard', required: true }, limit: { type: 'number', description: 'Maximum matches, default 20' } },
    async run(args) {
      const q = text(args.q, 'query', 80, true);
      const limit = number(args.limit, 'limit', 1, 50, 20);
      const managers = await search13FManagers(q, limit);
      const rows: Row[] = managers.map(manager => ({
        label: manager.name,
        value: `As of ${manager.period}`,
        detail: `CIK ${manager.cik} · Filed ${manager.filed}`,
        date: manager.filed,
        url: `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${manager.cik}&type=13F-HR`,
        destination: `data:sec/institutions?manager=${manager.cik}`,
      }));
      return { title: `SEC 13F filers matching “${q}”`, source: 'SEC EDGAR', url: 'https://www.sec.gov/search-filings',
        note: 'Each result is a filer with a recent quarterly 13F-HR. Newly filing managers appear through SEC records automatically. Parent companies and separately reporting affiliates remain separate filers.',
        sections: [{ title: `Managers · ${rows.length}`, rows }] };
    },
  },
  {
    name: 'institutional_flow', path: 'finviz/institutional-flow', description: 'Market-wide changes in aggregate institutional ownership from Finviz, split between companies with at least 18 months of trading history and recent or unknown listings. It does not identify individual managers or same-day trades.',
    params: { side: { type: 'string', description: 'Direction: buying or selling', enum: ['buying', 'selling'] } },
    async run(args) {
      const side = pick(args.side, 'side', ['buying', 'selling'], 'buying');
      const transactionFilter = side === 'buying' ? 'sh_insttrans_o10' : 'sh_insttrans_u10';
      const sort = side === 'buying' ? '-insttrans' : 'insttrans';
      const filters = ['ind_stocksonly', 'cap_largeover', 'sh_price_o5', 'sh_avgvol_o500', 'sh_instown_o20', transactionFilter].join(',');
      const url = `https://finviz.com/screener.ashx?v=131&f=${filters}&ft=4&o=${sort}`;
      const html = await cached(`finviz/institutional-flow/v1/${side}`, 1800, () => getText(url, {
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36', Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }, timeout: 12000,
      }));
      const clean = (value: string) => value.replace(/<[^>]*>/g, ' ').replace(/&nbsp;|&#160;|&#xA0;/gi, ' ').replace(/&amp;/gi, '&').replace(/&quot;/gi, '"').replace(/&#39;|&#x27;/gi, "'").replace(/&#(\d+);/g, (_, n: string) => String.fromCodePoint(Number(n))).replace(/&#x([0-9a-f]+);/gi, (_, n: string) => String.fromCodePoint(parseInt(n, 16))).replace(/\s+/g, ' ').trim();
      const headers = [...html.matchAll(/<th\b[^>]*>([\s\S]*?)<\/th>/gi)].map(([, value]) => clean(value)).filter(Boolean);
      const headerStart = headers.indexOf('No.');
      const columns = headerStart >= 0 ? headers.slice(headerStart) : headers;
      const rows = [...html.matchAll(/<tr\b[^>]*class=["'][^"']*\bstyled-row[^"']*["'][^>]*>([\s\S]*?)<\/tr>/gi)].map(([, source]) => {
        const cells = [...source.matchAll(/<td\b[^>]*>([\s\S]*?)<\/td>/gi)].map(([, value]) => clean(value));
        const cell = (name: string) => cells[columns.indexOf(name)] ?? '';
        const ticker = /data-boxover-ticker=["']([^"']+)/i.exec(source)?.[1] ?? cell('Ticker');
        const company = /data-boxover-company=["']([^"']+)/i.exec(source)?.[1] ?? '';
        return { ticker, company: clean(company), marketCap: cell('Market Cap'), instOwn: cell('Inst Own'), instTrans: cell('Inst Trans'), price: cell('Price'), dailyChange: cell('Change %') };
      }).filter(row => /^[A-Z0-9.^-]{1,12}$/.test(row.ticker) && row.instTrans.endsWith('%'));
      if (!rows.length || !columns.includes('Ticker') || !columns.includes('Inst Trans')) throw new DataError(502, 'Finviz institutional ownership screen is temporarily unavailable');
      const count = Number(/#\s*\d+\s*\/\s*(\d+)/.exec(html)?.[1] ?? rows.length);
      const signedText = (value: string) => {
        const parsed = Number(value.replace('%', '').replace('−', '-'));
        return `${parsed >= 0 ? '+' : '−'}${fmt(Math.abs(parsed), 1)}%`;
      };
      type ListedHolder = { organization?: string; value?: { raw?: number }; reportDate?: { fmt?: string } };
      const listed = await mapLimited(rows.slice(0, 20), async (row, index) => {
        const holdersTask = index < 8
          ? cached(`yahoo/holders/v1/${row.ticker}`, 21600, () => yahooAuthed<{
              quoteSummary?: {
                result?: Array<{ institutionOwnership?: { ownershipList?: ListedHolder[] } }>;
              };
            }>(`https://query2.finance.yahoo.com/v10/finance/quoteSummary/${encodeURIComponent(row.ticker)}?modules=institutionOwnership`))
              .then(data => data.quoteSummary?.result?.[0]?.institutionOwnership?.ownershipList ?? [])
              .catch(() => [] as ListedHolder[])
          : Promise.resolve([] as ListedHolder[]);
        const [firstTradeDate, holders] = await Promise.all([yahooFirstTradeDate(row.ticker), holdersTask]);
        return { ...row, firstTradeDate, holders };
      }, 4);
      const cutoff = Date.now() - 548 * day;
      const established = listed.filter(row => row.firstTradeDate && Date.parse(row.firstTradeDate) <= cutoff);
      const recent = listed.filter(row => row.firstTradeDate && Date.parse(row.firstTradeDate) > cutoff);
      const unknown = listed.filter(row => !row.firstTradeDate);
      const percentValue = (value: string) => Number(value.replace('%', '').replace('−', '-').replace('+', '').trim());
      const holderTotals = new Map<string, { value: number; symbols: Set<string>; dates: Set<string> }>();
      for (const row of listed.slice(0, 8)) for (const holder of row.holders) {
        const name = holder.organization?.trim();
        const value = holder.value?.raw;
        if (!name || !Number.isFinite(value) || !value || value <= 0) continue;
        const total = holderTotals.get(name) ?? { value: 0, symbols: new Set<string>(), dates: new Set<string>() };
        total.value += value;
        total.symbols.add(row.ticker);
        if (holder.reportDate?.fmt) total.dates.add(holder.reportDate.fmt);
        holderTotals.set(name, total);
      }
      const topHolders = [...holderTotals.entries()].sort((a, b) => b[1].value - a[1].value).slice(0, 10).map(([name, total]) => {
        const latestReport = [...total.dates].sort((a, b) => (Date.parse(b) || 0) - (Date.parse(a) || 0))[0];
        return {
          label: name, value: money(total.value),
          detail: `Reported positions in ${total.symbols.size} of the top 8 screened stocks${latestReport ? ` · latest report ${latestReport}` : ''}`,
          change_label: `${total.symbols.size} STOCKS`, destination: `data:sec/institution-search?q=${encodeURIComponent(name)}`,
        };
      });
      const topPerformers = [...listed].filter(row => row.dailyChange.endsWith('%') && Number.isFinite(percentValue(row.dailyChange)))
        .sort((a, b) => percentValue(b.dailyChange) - percentValue(a.dailyChange)).slice(0, 10).map(row => ({
          label: row.ticker, symbol: row.ticker, value: signed(percentValue(row.dailyChange), 2, '%'), change: percentValue(row.dailyChange), change_label: 'TODAY',
          detail: `${row.company ? `${row.company} · ` : ''}Daily price change · Price $${row.price || '—'} · Institutional ownership change ${signed(percentValue(row.instTrans), 1, '%')}`,
        }));
      const resultRows = (items: typeof listed, group: 'established' | 'recent' | 'unknown'): Row[] => items.map(row => ({
        label: row.ticker, symbol: row.ticker, value: signedText(row.instTrans),
        detail: `${row.company ? `${row.company} · ` : ''}Institutional ownership ${row.instOwn || '—'} · Market cap ${row.marketCap || '—'} · Price $${row.price || '—'} · ${group === 'unknown' ? 'Listing date unavailable' : `First traded ${row.firstTradeDate}`}${group === 'recent' ? ' · Limited history; IPO or spinoff allocations can distort this change' : ''}`,
        change_label: group === 'established' ? 'OWNERSHIP CHANGE' : group === 'recent' ? 'RECENT LISTING' : 'AGE UNKNOWN',
        change: Number(row.instTrans.replace('%', '').replace('−', '-')),
      }));
      const title = side === 'buying' ? 'Stocks with rising institutional ownership' : 'Stocks with falling institutional ownership';
      const direction = side === 'buying' ? 'increases' : 'decreases';
      return { title, source: 'Finviz Stock Screener + Yahoo Finance ownership filings', url,
        note: `Finviz's Institutional Transactions is a change in aggregate reported ownership, not a record of purchases or same-day trading. Recent listings are separated because IPO allocations and spinoff distributions can distort quarter-over-quarter comparisons. Established means at least 18 months since first trading. Top holders aggregates Yahoo Finance institution positions across the first 8 screened stocks; 13F and N-PORT disclosures are delayed snapshots. Top performers uses Finviz's daily Change % for the same screened stocks. Use INST <manager> to compare a specific filer's delayed SEC 13F snapshots. ${Math.min(count, 20)} of ${count} matches screened.`,
        sections: [
          { title: 'Top holders · institutional ownership', rows: topHolders },
          { title: 'Top performers today · daily change', rows: topPerformers },
          { title: `${direction} · listed 18+ months`, rows: resultRows(established, 'established') },
          { title: 'Recently listed · under 18 months', rows: resultRows(recent, 'recent') },
          { title: 'Listing history unavailable', rows: resultRows(unknown, 'unknown') },
        ] };
    },
  },
  {
    name: 'institutional_positions', path: 'sec/institutions', description: 'Quarter-over-quarter changes in an institutional manager’s disclosed Form 13F holdings, including new positions, increases, reductions and exits. Filings are delayed snapshots, not daily trades.',
    params: { manager: { type: 'string', description: 'SEC Central Index Key (CIK) of a 13F filer; defaults to BlackRock' }, period: { type: 'string', description: 'Optional report date (YYYY-MM-DD) for a historical 13F snapshot' }, offset: { type: 'number', description: 'Zero-based offset into the complete position list' }, page_size: { type: 'number', description: 'Positions per page, default 150 and maximum 250' } },
    async run(args) {
      const rawCIK = text(args.manager, 'manager', 10) || '0002012383';
      if (!/^\d{1,10}$/.test(rawCIK)) throw new DataError(400, 'Choose a manager from sec/institution-search');
      const managerCIK = rawCIK.padStart(10, '0');
      const profile = await submissions(managerCIK);
      const managerName = profile.name ?? `SEC filer ${managerCIK}`;
      const allFilings = await historical13FFilings(profile);
      const selectedPeriod = text(args.period, 'period', 10);
      const selectedIndex = selectedPeriod ? allFilings.findIndex(filing => filing.period === selectedPeriod) : 0;
      if (selectedPeriod && selectedIndex < 0) throw new DataError(404, `No 13F snapshot found for ${selectedPeriod}`);
      const filings = allFilings.slice(selectedIndex, selectedIndex + 2);
      if (!filings.length) throw new DataError(404, `No recent 13F filings found for ${managerName}`);
      const current = await filing13FTable(managerCIK, filings[0].accession);
      const previous = filings.length > 1 ? await filing13FTable(managerCIK, filings[1].accession) : undefined;
      const issuerSymbols = await secIssuerSymbols();
      const aggregate = (rows: ThirteenFRow[]) => {
        const map = new Map<string, ThirteenFRow>();
        for (const entry of rows) {
          const held = map.get(entry.cusip);
          if (held) { held.value += entry.value; held.shares += entry.shares; }
          else map.set(entry.cusip, { ...entry });
        }
        return map;
      };
      const latest = current.rows, prior = previous?.rows ?? new Map<string, ThirteenFRow>();
      const offset = number(args.offset, 'offset', 0, 100000, 0);
      const pageSize = number(args.page_size, 'page_size', 25, 250, 150);
      type Change = { holding: ThirteenFRow; cusip: string; old?: ThirteenFRow; delta: number; percent: number; dollars: number };
      const top = (items: Change[], item: Change, score: (value: Change) => number) => {
        if (items.length < 15) { items.push(item); return; }
        let worst = 0;
        for (let i = 1; i < items.length; i++) if (score(items[i]) < score(items[worst])) worst = i;
        if (score(item) > score(items[worst])) items[worst] = item;
      };
      const added: Change[] = [], increased: Change[] = [], reduced: Change[] = [], exited: { holding: ThirteenFRow; cusip: string }[] = [];
      let addedCount = 0, increasedCount = 0, reducedCount = 0, exitedCount = 0, currentValue = 0;
      for (const [cusip, holding] of latest) {
        currentValue += holding.value;
        const old = prior.get(cusip);
        const delta = holding.shares - (old?.shares ?? 0);
        const percent = old?.shares ? delta / old.shares * 100 : 0;
        const dollars = holding.shares ? Math.abs(delta) * holding.value / holding.shares : 0;
        const item = { holding, cusip, old, delta, percent, dollars };
        if (!old) { addedCount++; top(added, item, value => value.holding.value); }
        else if (delta > 0) { increasedCount++; top(increased, item, value => value.dollars); }
        else if (delta < 0) { reducedCount++; top(reduced, item, value => value.dollars); }
      }
      let priorValue = 0;
      for (const [cusip, holding] of prior) {
        priorValue += holding.value;
        if (!latest.has(cusip)) { exitedCount++; exited.push({ holding, cusip }); }
      }
      const makeChangeRow = (item: Change, kind: 'NEW' | 'INCREASED' | 'REDUCED'): Row => {
        const amount = Math.round(Math.abs(item.delta)).toLocaleString('en-US');
        const signedPercent = `${item.percent > 0 ? '+' : item.percent < 0 ? '−' : ''}${fmt(Math.abs(item.percent), 1)}%`;
        const changeLabel = kind === 'NEW' ? 'NEW' : kind === 'INCREASED' ? `+${amount} (${signedPercent}) shares` : `−${amount} (${signedPercent}) shares`;
        return { label: item.holding.issuer, value: money(item.holding.value), detail: `CUSIP ${item.cusip} · ${Math.round(item.holding.shares).toLocaleString('en-US')} shares${item.old ? ` · prior ${Math.round(item.old.shares).toLocaleString('en-US')}` : ''}`, change_label: changeLabel, symbol: issuerSymbols[issuerKey(item.holding.issuer)] };
      };
      const addedRows = added.sort((a, b) => b.holding.value - a.holding.value).map(item => makeChangeRow(item, 'NEW'));
      const increasedRows = increased.sort((a, b) => b.dollars - a.dollars).map(item => makeChangeRow(item, 'INCREASED'));
      const reducedRows = reduced.sort((a, b) => b.dollars - a.dollars).map(item => makeChangeRow(item, 'REDUCED'));
      const exitedRows = exited.sort((a, b) => b.holding.value - a.holding.value).slice(0, 15).map(({ holding, cusip }) => ({ label: holding.issuer, value: money(holding.value), detail: `CUSIP ${cusip} · ${Math.round(holding.shares).toLocaleString('en-US')} shares in prior report`, change_label: 'EXITED', symbol: issuerSymbols[issuerKey(holding.issuer)] }));
      const sortedCUSIPs = [...latest.keys()].sort((a, b) => latest.get(b)!.value - latest.get(a)!.value);
      const pageCUSIPs = sortedCUSIPs.slice(offset, offset + pageSize);
      const holdings = pageCUSIPs.map(cusip => {
        const holding = latest.get(cusip)!;
        return { label: holding.issuer, value: money(holding.value), detail: `CUSIP ${cusip} · ${Math.round(holding.shares).toLocaleString('en-US')} shares`, symbol: issuerSymbols[issuerKey(holding.issuer)] };
      });
      const valueDelta = currentValue - priorValue;
      const signedMoney = `${valueDelta > 0 ? '+' : valueDelta < 0 ? '−' : ''}${money(Math.abs(valueDelta))}`;
      const overview: Row[] = [
        { label: 'Reporting period', value: filings[0].period, detail: `Filed ${filings[0].date}` },
        { label: 'Reported 13F value', value: money(currentValue), detail: previous ? `Prior ${money(priorValue)} · reported value change ${signedMoney}` : 'Prior filing unavailable' },
        { label: 'New positions', value: String(addedCount), detail: `Top ${Math.min(15, addedCount)} shown` },
        { label: 'Increased positions', value: String(increasedCount), detail: `Top ${Math.min(15, increasedCount)} shown` },
        { label: 'Reduced positions', value: String(reducedCount), detail: `Top ${Math.min(15, reducedCount)} shown` },
        { label: 'Exited positions', value: String(exitedCount), detail: `Top ${Math.min(15, exitedCount)} shown` },
      ];
      const filingRows = filings.map((filing, index) => ({ label: index === 0 ? `Latest snapshot · as of ${filing.period}` : `Prior snapshot · as of ${filing.period}`, value: `Filed ${filing.date}`, date: filing.date, url: filingURL(managerCIK, filing.accession, filing.document), detail: filing.accession }));
      const historyRows = allFilings.map(filing => ({ label: `As of ${filing.period}`, value: `Filed ${filing.date}`, date: filing.date, destination: `data:sec/institutions?manager=${managerCIK}&period=${filing.period}` }));
      return { title: `${managerName} institutional positions`, source: 'SEC EDGAR Form 13F', url: `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${managerCIK}&type=13F-HR`,
        note: previous ? `Positions as of ${filings[0].period}, filed ${filings[0].date}; compared with positions as of ${filings[1].period}, filed ${filings[1].date}. 13F covers reportable Section 13(f) securities, not the manager’s entire portfolio. Reports are generally due up to 45 days after quarter end. These are disclosed share-count changes, not trades made today; options, confidential treatment and separately filed manager entities can affect comparisons.` : `Latest available filing: positions as of ${filings[0].period}, filed ${filings[0].date}. Form 13F is a delayed snapshot of reportable Section 13(f) securities, not the manager’s entire portfolio or a daily trade feed.`,
        page: { total: latest.size, offset, limit: pageSize },
        sections: [
          { title: 'Quarter overview', rows: overview },
          { title: 'All reported positions', rows: holdings },
          { title: 'New positions', rows: addedRows }, { title: 'Increased positions', rows: increasedRows },
          { title: 'Reduced positions', rows: reducedRows }, { title: 'Exited positions', rows: exitedRows }, { title: 'Recent filings', rows: filingRows },
          { title: 'Historical quarters', rows: historyRows },
        ] };
    },
  },
  {
    name: 'congressional_ptrs', path: 'congress/ptrs', description: 'Recently filed U.S. House Periodic Transaction Reports. Tap a filing to extract its reported assets, transaction types, dates and amount ranges on device, with a link to the official PDF.',
    params: { days: { type: 'number', description: 'Filing lookback window in days, default 90' }, member: { type: 'string', description: 'Optional member name or surname filter' }, limit: { type: 'number', description: 'Maximum reports, default 50' } },
    async run(args) {
      const days = number(args.days, 'days', 1, 3650, 90);
      const member = text(args.member, 'member', 80).toLowerCase();
      const limit = number(args.limit, 'limit', 1, 100, 50);
      const reports = await housePTRIndex(new Date().getUTCFullYear());
      const cutoff = Date.now() - days * day;
      const rows: Row[] = reports.filter(report => report.filedAt >= cutoff && (!member || report.name.toLowerCase().includes(member)))
        .sort((a, b) => b.filedAt - a.filedAt || a.name.localeCompare(b.name)).slice(0, limit).map(report => {
          const year = new Date(report.filedAt).getUTCFullYear();
          return {
            label: report.name,
            value: 'View reported trades',
            detail: `${report.district} · Filed ${report.filed} · Tap to extract transactions`,
            date: report.filed,
            url: `https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/${year}/${report.id}.pdf`,
            ptr_id: report.id,
            ptr_year: year,
          };
        });
      return { title: member ? `House disclosures · ${member}` : 'Recent House transaction disclosures', source: 'U.S. House Clerk · Financial Disclosure Reports', url: 'https://disclosures-clerk.house.gov/FinancialDisclosure',
        note: 'Tap a filing to read its reported assets, transaction dates, purchase or sale type, and amount range. House reports may cover a member, spouse, or dependent child; the filing date can lag the trade date. The original Clerk PDF remains available from each detail page.',
        sections: [{ title: `${days}-day filing window · ${rows.length} reports`, rows }] };
    },
  },
  {
    name: 'insider_trades', path: 'sec/insiders', description: 'Recent Form 4 insider transactions for a US-listed company: who traded, their role, buy or sell, shares and value, parsed from SEC filings.',
    params: { symbol: { type: 'string', description: 'US ticker', required: true }, limit: { type: 'number', description: 'Filings to read, default 10, maximum 20' } },
    async run(args) {
      const company = await cik(args.symbol);
      const limit = number(args.limit, 'limit', 1, 20, 10);
      const recent = (await submissions(company.cik)).filings.recent;
      const filings = recent.form.flatMap((f, i) => f === '4' ? [i] : []).slice(0, limit);
      const parsed = await Promise.all(filings.map(async i => {
        const url = `https://www.sec.gov/Archives/edgar/data/${Number(company.cik)}/${recent.accessionNumber[i].replaceAll('-', '')}/${recent.primaryDocument[i].split('/').pop()}`;
        const xml = await cached(`sec/form4/v1/${recent.accessionNumber[i]}`, 604800, () => getText(url, { headers: { 'User-Agent': sec } })).catch(() => '');
        return { xml, date: recent.filingDate[i], url: filingURL(company.cik, recent.accessionNumber[i], recent.primaryDocument[i]) };
      }));
      const rows = parsed.flatMap(({ xml, date, url }) => xml ? form4(xml).map(t => ({ ...t, date, url })) : []);
      return { title: `${company.name} insider transactions`, source: 'SEC EDGAR Form 4', url: `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${company.cik}&type=4`,
        note: 'Codes: P open-market buy, S open-market sale, A grant, M option exercise, F tax withholding, G gift. Values use prices stated in the filing.', sections: [{ title: 'Transactions', rows }] };
    },
  },
  {
    name: 'holders', path: 'sec/holders', description: 'Institutional and insider ownership for a stock: percent held by insiders and institutions and the largest institutional and fund holders as reported in 13F and N-PORT filings.',
    params: { symbol: { type: 'string', description: 'Ticker', required: true } },
    async run(args) {
      const symbol = text(args.symbol, 'symbol', 20, true).toUpperCase();
      if (!/^[A-Z0-9.\-^=]{1,20}$/.test(symbol)) throw new DataError(400, 'Invalid symbol');
      type Holder = { organization?: string; pctHeld?: { raw?: number }; position?: { raw?: number }; value?: { raw?: number }; reportDate?: { fmt?: string }; pctChange?: { raw?: number } };
      const data = await cached(`yahoo/holders/v1/${symbol}`, 21600, () => yahooAuthed<{ quoteSummary?: { result?: Record<string, { ownershipList?: Holder[] } & Record<string, { raw?: number }>>[] } }>(
        `https://query2.finance.yahoo.com/v10/finance/quoteSummary/${encodeURIComponent(symbol)}?modules=majorHoldersBreakdown,institutionOwnership,fundOwnership`));
      const result = data.quoteSummary?.result?.[0];
      if (!result) throw new DataError(404, `No ownership data for ${symbol}`);
      const breakdown = result.majorHoldersBreakdown as unknown as Record<string, { raw?: number }> | undefined;
      const pct = (value?: number) => value === undefined ? 'n/a' : `${fmt(value * 100, 1)}%`;
      const holders = (list?: Holder[]) => (list ?? []).slice(0, 10).map(h => ({ label: h.organization ?? 'Unknown', value: pct(h.pctHeld?.raw), detail: `${(h.position?.raw ?? 0).toLocaleString('en-US')} shares · ${money(h.value?.raw ?? 0)}`, date: h.reportDate?.fmt,
        change_label: h.pctChange?.raw !== undefined ? `${signed(h.pctChange.raw * 100, 1, '%')} position change` : undefined }));
      return { title: `${symbol} ownership`, source: 'Yahoo Finance (13F and N-PORT filings)', url: `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}/holders/`,
        sections: [
          { title: 'Breakdown', rows: [{ label: 'Insiders', value: pct(breakdown?.insidersPercentHeld?.raw) }, { label: 'Institutions', value: pct(breakdown?.institutionsPercentHeld?.raw) }, { label: 'Institutions holding', value: String(breakdown?.institutionsCount?.raw ?? 'n/a') }] },
          { title: 'Top institutions', rows: holders(result.institutionOwnership?.ownershipList) },
          { title: 'Top funds', rows: holders(result.fundOwnership?.ownershipList) },
        ] };
    },
  },
  {
    name: 'contracts', path: 'contracts', description: 'Federal contract awards to a company from USAspending.gov: total obligated over a period and the largest recent contract actions with agency and description. Defense data can lag 90 days.',
    params: { company: { type: 'string', description: 'Recipient name, for example Lockheed Martin or Palantir', required: true }, days: { type: 'number', description: 'Look-back window in days, default 365' } },
    async run(args) {
      const company = text(args.company, 'company', 100, true);
      const days = number(args.days, 'days', 7, 3650, 365);
      const filters = { recipient_search_text: [company], award_type_codes: ['A', 'B', 'C', 'D'], time_period: [{ start_date: ymd(Date.now() - days * day), end_date: ymd() }] };
      const post = <T>(path: string, body: unknown) => cached(`usaspending/v1/${path}/${encodeURIComponent(company.toLowerCase())}/${days}`, 21600, () => getJSON<T>(`https://api.usaspending.gov/api/v2/${path}/`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), timeout: 15000 }));
      let totals: { results?: { name: string; amount: number }[] }, actions: { results?: Record<string, string | number>[] };
      try {
        [totals, actions] = await Promise.all([
          post<{ results?: { name: string; amount: number }[] }>('search/spending_by_category/recipient', { filters, limit: 8, page: 1 }),
          post<{ results?: Record<string, string | number>[] }>('search/spending_by_transaction', { filters, fields: ['Award ID', 'Recipient Name', 'Transaction Amount', 'Action Date', 'Transaction Description', 'Awarding Agency', 'Awarding Sub Agency', 'generated_internal_id'], limit: 15, sort: 'Transaction Amount', order: 'desc' }),
        ]);
      } catch {
        // USAspending's TLS endpoint rejects Cloudflare's edge (HTTP 525); FPDS, the system it is built from, answers the same question.
        const date = (ms: number) => ymd(ms).replaceAll('-', '/');
        const feed = await cached(`fpds/v1/${encodeURIComponent(company.toLowerCase())}/${days}`, 21600, () => getText(`https://www.fpds.gov/ezsearch/FEEDS/ATOM?FEEDNAME=PUBLIC&q=${encodeURIComponent(`${company} SIGNED_DATE:[${date(Date.now() - days * day)},${date(Date.now())}]`)}&sortBy=OBLIGATED_AMOUNT&desc=Y`, { timeout: 25000 }));
        return { title: `Federal contracts: ${company}`, source: 'FPDS (Federal Procurement Data System)', url: `https://www.fpds.gov/ezsearch/search.do?q=${encodeURIComponent(company)}&s=FPDS&indexName=awardfull`,
          note: `Largest contract actions signed in the last ${days} days, matched by text search. Defense data can lag 90 days.`, sections: [{ title: 'Largest contract actions', rows: fpdsRows(feed) }] };
      }
      const totalRows = (totals.results ?? []).map(r => ({ label: r.name, value: money(r.amount) }));
      const actionRows = (actions.results ?? []).map(r => ({ label: String(r['Transaction Description'] || r['Award ID']).slice(0, 160), value: money(Number(r['Transaction Amount'])), date: String(r['Action Date']),
        detail: [r['Recipient Name'], r['Awarding Sub Agency'] || r['Awarding Agency']].filter(Boolean).join(' · '), url: `https://www.usaspending.gov/award/${r.generated_internal_id}` }));
      return { title: `Federal contracts: ${company}`, source: 'USAspending.gov', url: `https://www.usaspending.gov/search`, note: `Contract obligations over the last ${days} days. Recipient matching is by name and may include subsidiaries or similarly named firms.`,
        sections: [{ title: 'Obligated by recipient', rows: totalRows }, { title: 'Largest contract actions', rows: actionRows }] };
    },
  },
  {
    name: 'chokepoints', path: 'chokepoints', description: 'Daily ship transits through maritime chokepoints (Strait of Hormuz, Suez Canal, Panama Canal, Bab el-Mandeb, Malacca, Bosporus and others) from IMF PortWatch, with the last 7 days compared to the prior 30.',
    params: { name: { type: 'string', description: 'Optional chokepoint name filter, for example hormuz or suez' } },
    async run(args) {
      const filter = text(args.name, 'name', 40).toLowerCase();
      const rows = chokepointRows(await portWatch()).filter(r => !filter || r.label.toLowerCase().includes(filter));
      const chart = filter && rows.length === 1 ? { label: `${rows[0].label} daily transits`, points: (rows[0].points ?? []).map((value, i, all) => ({ x: ymd(Date.now() - (all.length - i) * day), value })) } : undefined;
      return { title: 'Maritime chokepoint transits', source: 'IMF PortWatch (AIS satellite data)', url: 'https://portwatch.imf.org/pages/chokepoints', note: 'Average daily vessel transits, last 7 days vs the 30 days before. Recent days may be revised.', sections: [{ title: 'Chokepoints', rows }], chart };
    },
  },
  {
    name: 'ships', path: 'ships', description: 'Live ship positions near a maritime chokepoint from AIS (AISStream), refreshed every few minutes: vessels by type, how many are moving versus stopped, and a map of positions.',
    params: { area: { type: 'string', description: 'Chokepoint', enum: Object.keys(shipAreas), required: true } },
    async run(args, env) {
      const area = pick(args.area, 'area', Object.keys(shipAreas), 'hormuz');
      const zone = shipAreas[area];
      const { results } = await env.DB.prepare('SELECT * FROM ship_positions WHERE area = ? AND at >= ? ORDER BY speed DESC LIMIT 600').bind(area, iso(Date.now() - 6 * 3600000)).all<{ mmsi: string; name: string; kind: string; lat: number; lon: number; speed: number; course: number; at: string }>();
      if (!results.length) {
        const transits = chokepointRows(await portWatch().catch(() => [])).find(r => r.label === zone.portwatch);
        const chart = transits?.points?.length ? { label: `${zone.portwatch} daily transits`, unit: 'ships/day', points: transits.points.map((value, i, all) => ({ x: ymd(Date.now() - (all.length - i) * day), value })) } : undefined;
        return { title: `Ships near ${zone.name}`, source: 'IMF PortWatch (AIS satellite data)', url: 'https://portwatch.imf.org/pages/chokepoints',
          note: 'Live vessel positions are off: no AIS positions arrived in the last six hours. Daily transit counts from IMF PortWatch are shown instead.',
          sections: transits ? [{ title: 'Daily transits', rows: [transits] }] : [],
          chart, map: { center: zone.center, span: zone.span, pins: [] } };
      }
      const kinds = new Map<string, { total: number; moving: number }>();
      for (const ship of results) {
        const entry = kinds.get(ship.kind) ?? { total: 0, moving: 0 };
        entry.total++; if (ship.speed >= 1) entry.moving++;
        kinds.set(ship.kind, entry);
      }
      const latest = results.map(r => r.at).sort().at(-1)!;
      return { title: `Ships near ${zone.name}`, source: 'AISStream (terrestrial AIS, coverage varies)', url: 'https://aisstream.io', as_of: latest,
        note: `${results.length} vessels reported in the last six hours; ${results.filter(r => r.speed >= 1).length} under way.`,
        sections: [
          { title: 'By type', rows: [...kinds].sort((a, b) => b[1].total - a[1].total).map(([kind, v]) => ({ label: kind, value: `${v.total}`, detail: `${v.moving} under way` })) },
          { title: 'Fastest under way', rows: results.filter(r => r.speed >= 1).slice(0, 12).map(r => ({ label: r.name || r.mmsi, value: `${fmt(r.speed, 1)} kn`, detail: `${r.kind} · heading ${Math.round(r.course)}°` })) },
        ],
        map: { center: zone.center, span: zone.span, pins: results.slice(0, 400).map(r => ({ lat: r.lat, lon: r.lon, label: r.name || r.mmsi, detail: `${r.kind} · ${fmt(r.speed, 1)} kn`, heading: r.course, kind: r.kind })) } };
    },
  },
  {
    name: 'world_economy', path: 'world', description: 'IMF World Economic Outlook figures and forecasts by country: real GDP growth, inflation, unemployment, government debt to GDP, current account.',
    params: { indicator: { type: 'string', description: 'gdp (default), inflation, unemployment, debt or current_account', enum: ['gdp', 'inflation', 'unemployment', 'debt', 'current_account'] },
      countries: { type: 'string', description: 'Comma-separated ISO3 codes; default major economies' } },
    async run(args) {
      const indicators: Record<string, [string, string]> = { gdp: ['NGDP_RPCH', 'Real GDP growth, %'], inflation: ['PCPIPCH', 'Inflation, average consumer prices, %'], unemployment: ['LUR', 'Unemployment rate, %'], debt: ['GGXWDG_NGDP', 'General government gross debt, % of GDP'], current_account: ['BCA_NGDPD', 'Current account balance, % of GDP'] };
      const key = pick(args.indicator, 'indicator', Object.keys(indicators), 'gdp');
      const countries = (text(args.countries, 'countries', 200) || 'USA,CHN,JPN,DEU,GBR,FRA,ITA,CAN,IND,BRA,KOR,MEX').toUpperCase().split(',').map(c => c.trim()).filter(Boolean);
      if (countries.length > 30 || countries.some(c => !/^[A-Z]{3}$/.test(c))) throw new DataError(400, 'Invalid countries');
      const [code, label] = indicators[key];
      const data = await cached(`imf/v1/${code}`, 86400, () => getJSON<{ values?: Record<string, Record<string, Record<string, number>>> }>(`https://www.imf.org/external/datamapper/api/v1/${code}`, { timeout: 15000 }));
      const names = await cached('imf/countries/v1', 604800, () => getJSON<{ countries?: Record<string, { label?: string }> }>('https://www.imf.org/external/datamapper/api/v1/countries')).catch(() => ({ countries: {} as Record<string, { label?: string }> }));
      const year = new Date().getUTCFullYear();
      const rows = countries.map(c => {
        const values = data.values?.[code]?.[c] ?? {};
        const now = values[year], next = values[year + 1], last = values[year - 1];
        return { label: names.countries?.[c]?.label ?? c, value: now === undefined ? 'n/a' : `${fmt(now, 1)}`, detail: `${year - 1}: ${last === undefined ? 'n/a' : fmt(last, 1)} · ${year + 1}: ${next === undefined ? 'n/a' : fmt(next, 1)}` };
      });
      return { title: `${label} (${year})`, source: 'IMF World Economic Outlook DataMapper', url: `https://www.imf.org/external/datamapper/${code}`, note: 'Current and next year are IMF estimates or forecasts.', sections: [{ title: 'Countries', rows }] };
    },
  },
];

export function fpdsRows(xml: string): Row[] {
  const decode = (value: string) => value.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;|&#39;/g, "'").trim();
  return [...xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)].flatMap(([, entry]) => {
    const tag = (name: string) => new RegExp(`<ns1:${name}[^>]*>([^<]*)<`).exec(entry)?.[1] ?? '';
    const attr = (name: string) => new RegExp(`<ns1:${name} name="([^"]*)"`).exec(entry)?.[1] ?? '';
    const amount = Number(tag('obligatedAmount'));
    if (!Number.isFinite(amount)) return [];
    const piid = tag('PIID');
    return [{ label: decode(tag('descriptionOfContractRequirement') || piid).slice(0, 160), value: money(amount), date: tag('signedDate').slice(0, 10),
      detail: [decode(tag('vendorName') || attr('vendorName')), attr('contractingOfficeAgencyID')].filter(Boolean).join(' · ').toLowerCase().replace(/\b[a-z]/g, c => c.toUpperCase()),
      url: `https://www.fpds.gov/ezsearch/search.do?s=FPDS&indexName=awardfull&q=${encodeURIComponent(piid)}` }];
  });
}

function companyKey(name: string) {
  return name.toLowerCase().replace(/[^a-z0-9 ]/g, ' ').split(/\s+/).filter(w => w && !['inc', 'corp', 'corporation', 'co', 'ltd', 'plc', 'sa', 'ag', 'nv', 'se', 'the', 'company', 'limited', 'holdings', 'group', 'adr', 'motor'].includes(w)).slice(0, 2).join(' ');
}

export function ftsQuery(q: string): string {
  return q.toLowerCase().replace(/[^\p{L}\p{N}\s'-]/gu, ' ').split(/\s+/).filter(w => w.length > 1 && !['and', 'or', 'not', 'near'].includes(w)).slice(0, 8).map(w => `"${w.replace(/"/g, '')}"*`).join(' ');
}

export function blsEvents(ics: string): Row[] {
  return [...ics.matchAll(/BEGIN:VEVENT([\s\S]*?)END:VEVENT/g)].flatMap(([, block]) => {
    const start = /DTSTART[^:]*:(\d{8})T(\d{4})/.exec(block);
    const summary = /SUMMARY:(.+)/.exec(block)?.[1]?.trim();
    if (!start || !summary) return [];
    const date = `${start[1].slice(0, 4)}-${start[1].slice(4, 6)}-${start[1].slice(6, 8)}`;
    const hour = Number(start[2].slice(0, 2)), minute = start[2].slice(2);
    return [{ label: summary, value: `${hour > 12 ? hour - 12 : hour}:${minute} ${hour >= 12 ? 'PM' : 'AM'} ET`, date, detail: 'BLS', url: 'https://www.bls.gov/schedule/news_release/' }];
  });
}

export function chokepointRows(records: Record<string, string | number>[]): Row[] {
  const byName = new Map<string, { date: string; total: number; tanker: number }[]>();
  for (const r of records) {
    const date = typeof r.date === 'number' ? ymd(r.date) : String(r.date).slice(0, 10);
    byName.set(String(r.portname), [...(byName.get(String(r.portname)) ?? []), { date, total: Number(r.n_total), tanker: Number(r.n_tanker) }]);
  }
  const average = (values: number[]) => values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0;
  return [...byName].map(([name, list]) => {
    const days = list.sort((a, b) => a.date.localeCompare(b.date));
    const week = days.slice(-7), prior = days.slice(-37, -7);
    const recent = average(week.map(d => d.total)), base = average(prior.map(d => d.total));
    return { label: name, value: `${fmt(recent, 1)} ships/day`, date: days.at(-1)?.date, change: base ? round((recent / base - 1) * 100, 1) : undefined,
      detail: `tankers ${fmt(average(week.map(d => d.tanker)), 1)}/day · 30-day avg ${fmt(base, 1)}`, points: days.map(d => d.total) };
  }).sort((a, b) => parseFloat(b.value) - parseFloat(a.value));
}

export function form4(xml: string): Row[] {
  const field = (source: string, tag: string) => new RegExp(`<${tag}>\\s*(?:<value>)?\\s*([^<]*)`).exec(source)?.[1]?.trim() ?? '';
  const owner = field(xml, 'rptOwnerName');
  const role = field(xml, 'officerTitle') || (field(xml, 'isDirector') === '1' ? 'Director' : field(xml, 'isTenPercentOwner') === '1' ? '10% owner' : 'Insider');
  const labels: Record<string, string> = { P: 'Buy', S: 'Sale', A: 'Grant', M: 'Option exercise', F: 'Tax withholding', G: 'Gift', D: 'Disposition', C: 'Conversion' };
  return (xml.match(/<nonDerivativeTransaction>[\s\S]*?<\/nonDerivativeTransaction>/g) ?? []).flatMap(block => {
    const code = field(block, 'transactionCode'), shares = Number(field(block, 'transactionShares')), price = Number(field(block, 'transactionPricePerShare'));
    if (!code || !Number.isFinite(shares) || !shares) return [];
    return [{ label: `${owner} (${role})`, value: `${labels[code] ?? code} ${shares.toLocaleString('en-US')} sh`, detail: price ? `at $${fmt(price)} · ${money(shares * price)}` : 'no price stated' }];
  });
}

async function cik(value: string | undefined) {
  const symbol = text(value, 'symbol', 12, true).toUpperCase().replace('.', '-');
  const map = await cached('sec/tickers/v1', 86400, async () => {
    const data = await getJSON<Record<string, { cik_str: number; ticker: string; title: string }>>('https://www.sec.gov/files/company_tickers.json', { headers: { 'User-Agent': sec }, timeout: 15000 });
    return Object.fromEntries(Object.values(data).map(e => [e.ticker, [String(e.cik_str).padStart(10, '0'), e.title]]));
  }) as Record<string, [string, string]>;
  const hit = map[symbol];
  if (!hit) throw new DataError(404, `${symbol} is not an SEC registrant`);
  return { cik: hit[0], name: hit[1] };
}
interface FilingSet { form: string[]; filingDate: string[]; reportDate?: string[]; accessionNumber: string[]; primaryDocument: string[]; primaryDocDescription?: string[]; items?: string[] }
interface Submissions { name?: string; filings: { recent: FilingSet; files?: { name: string; filingFrom?: string; filingTo?: string }[] } }
const submissions = (id: string) => cached(`sec/submissions/v1/${id}`, 1800, () => getJSON<Submissions>(`https://data.sec.gov/submissions/CIK${id}.json`, { headers: { 'User-Agent': sec }, timeout: 15000 }));
interface HistoricalFiling { date: string; period: string; accession: string; document: string }
async function historical13FFilings(profile: Submissions): Promise<HistoricalFiling[]> {
  const filings: HistoricalFiling[] = [];
  const append = (set: FilingSet) => {
    for (let i = 0; i < set.form.length; i++) {
      if (set.form[i] !== '13F-HR' || !set.accessionNumber[i] || !set.primaryDocument[i]) continue;
      filings.push({ date: set.filingDate[i], period: set.reportDate?.[i] || 'unknown quarter end', accession: set.accessionNumber[i], document: set.primaryDocument[i] });
    }
  };
  append(profile.filings.recent);
  for (const file of [...(profile.filings.files ?? [])].reverse()) {
    if (filings.filter(filing => filing.period !== 'unknown quarter end').length >= 40) break;
    try {
      const older = await cached(`sec/submissions-archive/v1/${file.name}`, 86400, () => getJSON<FilingSet>(`https://data.sec.gov/submissions/${file.name}`, { headers: { 'User-Agent': sec }, timeout: 15000 }));
      append(older);
    } catch { }
  }
  const byPeriod = new Map<string, HistoricalFiling>();
  for (const filing of filings.filter(item => item.period !== 'unknown quarter end').sort((a, b) => b.date.localeCompare(a.date))) {
    if (!byPeriod.has(filing.period)) byPeriod.set(filing.period, filing);
  }
  return [...byPeriod.values()].sort((a, b) => b.period.localeCompare(a.period)).slice(0, 40);
}
const filingURL = (id: string, accession: string, document: string) => `https://www.sec.gov/Archives/edgar/data/${Number(id)}/${accession.replaceAll('-', '')}/${document.includes('/') ? `${accession}-index.htm` : document}`;

interface InstitutionFiler { name: string; cik: string; filed: string; period: string }
async function search13FManagers(query: string, limit: number): Promise<InstitutionFiler[]> {
  const normalizeName = (value: string) => value.toLowerCase()
    .replace(/\b(?:incorporated|corporation|corp|inc|company|co|limited|ltd|llc|llp|lp|plc)\b/g, ' ')
    .replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
  const normalizedQuery = normalizeName(query);
  const tokens = normalizedQuery.split(' ').filter(Boolean);
  if (!tokens.length) return [];
  const from = ymd(Date.now() - 548 * day);
  const to = ymd();
  const url = `https://efts.sec.gov/LATEST/search-index?entityName=${encodeURIComponent(normalizedQuery)}&forms=13F-HR&dateRange=custom&startdt=${from}&enddt=${to}`;
  const search = await cached(`sec/13f/search/v3/${encodeURIComponent(normalizedQuery)}`, 1800, () => getJSON<{
    hits?: { hits?: { _source?: { ciks?: string[]; display_names?: string[]; form?: string; file_date?: string; period_ending?: string } }[] }
  }>(url, { headers: { Accept: 'application/json', 'User-Agent': sec }, timeout: 15000 }));
  // Large managers file thousands of other forms, so their latest 13F can fall outside the submissions "recent" window; the search hit itself carries the filing and quarter dates.
  const latest = new Map<string, InstitutionFiler>();
  for (const hit of search.hits?.hits ?? []) {
    const filing = hit._source;
    if (filing?.form !== '13F-HR' || !filing.file_date) continue;
    (filing.ciks ?? []).forEach((rawCIK, index) => {
      const name = filing.display_names?.[index]?.replace(/\s+\(CIK \d+\).*$/i, '').replace(/\s+\([A-Z0-9.\-, ]{1,24}\)\s*$/, '').replace(/\s+/g, ' ').trim();
      if (!name || !tokens.every(token => normalizeName(name).split(' ').includes(token))) return;
      const cik = rawCIK.padStart(10, '0');
      const previous = latest.get(cik);
      if (previous && previous.filed >= filing.file_date!) return;
      latest.set(cik, { name, cik, filed: filing.file_date!, period: filing.period_ending || previous?.period || 'unknown quarter end' });
    });
  }
  const exact = (name: string) => normalizeName(name) === normalizedQuery ? 0 : 1;
  return [...latest.values()].sort((a, b) => exact(a.name) - exact(b.name) || b.filed.localeCompare(a.filed) || a.name.localeCompare(b.name)).slice(0, limit);
}

const issuerKey = (name: string) => name.toLowerCase().replace(/\b(?:incorporated|corporation|corp|inc|company|co|limited|ltd|plc|class|common|shares|stock)\b/g, ' ').replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
const secIssuerSymbols = () => cached('sec/issuer-tickers/v1', 86400, async () => {
  const data = await getJSON<Record<string, { ticker: string; title: string }>>('https://www.sec.gov/files/company_tickers.json', { headers: { 'User-Agent': sec }, timeout: 15000 });
  const map: Record<string, string> = {};
  const collisions = new Set<string>();
  for (const item of Object.values(data)) {
    const key = issuerKey(item.title);
    const symbol = item.ticker.replaceAll('.', '-');
    if (map[key] && map[key] !== symbol) collisions.add(key);
    else map[key] = symbol;
  }
  for (const key of collisions) delete map[key];
  return map;
}) as Promise<Record<string, string>>;

async function yahooFirstTradeDate(symbol: string): Promise<string | null> {
  return cached(`yahoo/first-trade-date/v1/${encodeURIComponent(symbol)}`, 86400, async () => {
    const data = await getJSON<{ chart?: { result?: { meta?: { firstTradeDate?: number } }[] } }>(
      `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=max&interval=1d`, { timeout: 8000 },
    );
    const seconds = data.chart?.result?.[0]?.meta?.firstTradeDate;
    if (!seconds || !Number.isFinite(seconds) || seconds > Date.now() / 1000 + 86400) return null;
    return new Date(seconds * 1000).toISOString().slice(0, 10);
  }).catch(() => null);
}

interface HousePTR { name: string; district: string; filed: string; filedAt: number; id: string }
function houseDate(value: string): number {
  const [month, dayOfMonth, year] = value.split('/').map(Number);
  if (![month, dayOfMonth, year].every(Number.isFinite) || month < 1 || month > 12 || dayOfMonth < 1 || dayOfMonth > 31 || year < 2000 || year > 2100) return NaN;
  return Date.UTC(year, month - 1, dayOfMonth, 12);
}
async function housePTRIndex(year: number): Promise<HousePTR[]> {
  return cached(`house/ptrs/index/v1/${year}`, 1800, async () => {
    const response = await get(`https://disclosures-clerk.house.gov/public_disc/financial-pdfs/${year}FD.ZIP`, { headers: { Accept: 'application/zip', 'User-Agent': agent }, timeout: 30000 });
    const bytes = new Uint8Array(await response.arrayBuffer());
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let offset = 0;
    let xml = '';
    while (offset + 30 < bytes.length) {
      if (view.getUint32(offset, true) !== 0x04034b50) { offset += 1; continue; }
      const method = view.getUint16(offset + 8, true);
      const compressedSize = view.getUint32(offset + 18, true);
      const nameLength = view.getUint16(offset + 26, true);
      const extraLength = view.getUint16(offset + 28, true);
      const nameStart = offset + 30;
      const dataStart = nameStart + nameLength + extraLength;
      const name = new TextDecoder().decode(bytes.subarray(nameStart, nameStart + nameLength));
      if (name.toLowerCase().endsWith('.xml') && compressedSize > 0) {
        if (method === 0) xml = new TextDecoder().decode(bytes.subarray(dataStart, dataStart + compressedSize));
        else if (method === 8) {
          const chunk = new ArrayBuffer(compressedSize);
          new Uint8Array(chunk).set(bytes.subarray(dataStart, dataStart + compressedSize));
          const stream = new Blob([chunk]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
          xml = await new Response(stream).text();
        }
        break;
      }
      offset = dataStart + Math.max(compressedSize, 1);
    }
    if (!xml) throw new DataError(502, 'House Clerk archive has no readable XML index');
    const field = (block: string, tag: string) => new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, 'i').exec(block)?.[1]
      ?.replace(/<[^>]*>/g, '').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').trim() ?? '';
    return [...xml.matchAll(/<Member\b[^>]*>([\s\S]*?)<\/Member>/gi)].flatMap(([, block]) => {
      if (field(block, 'FilingType') !== 'P') return [];
      const filedAt = houseDate(field(block, 'FilingDate'));
      const id = field(block, 'DocID');
      const name = [field(block, 'First'), field(block, 'Last')].filter(Boolean).join(' ');
      if (!Number.isFinite(filedAt) || !id || !name) return [];
      return [{ name, district: field(block, 'StateDst'), filed: new Date(filedAt).toISOString().slice(0, 10), filedAt, id }];
    });
  });
}

interface ThirteenFiling { form: string[]; filingDate: string[]; accessionNumber: string[]; primaryDocument: string[]; }
interface ThirteenFRow { issuer: string; cusip: string; value: number; shares: number; }
function xmlField(xml: string, tag: string): string {
  const match = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, 'i').exec(xml);
  return (match?.[1] ?? '').replace(/<[^>]*>/g, '').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').trim();
}
function xmlText(value: string): string {
  return value.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;|&#x27;/gi, "'")
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n: string) => String.fromCodePoint(parseInt(n, 16))).trim();
}
function parse13F(xml: string, filingYear: number): Map<string, ThirteenFRow> {
  const valueMultiplier = filingYear >= 2023 ? 1 : 1000;
  const rows = new Map<string, ThirteenFRow>();
  const tag = (name: string) => `(?:[\\w.-]+:)?${name}`;
  const pattern = new RegExp(`<${tag('infoTable')}\\b[^>]*>[\\s\\S]*?<${tag('nameOfIssuer')}\\b[^>]*>([^<]*)<\\/${tag('nameOfIssuer')}\\s*>[\\s\\S]*?<${tag('cusip')}\\b[^>]*>([^<]*)<\\/${tag('cusip')}\\s*>[\\s\\S]*?<${tag('value')}\\b[^>]*>([^<]*)<\\/${tag('value')}\\s*>[\\s\\S]*?<${tag('sshPrnamt')}\\b[^>]*>([^<]*)<\\/${tag('sshPrnamt')}\\s*>[\\s\\S]*?<\\/${tag('infoTable')}\\s*>`, 'gi');
  for (const match of xml.matchAll(pattern)) {
    const issuer = xmlText(match[1]), cusip = xmlText(match[2]);
    const value = Number(match[3].replaceAll(',', '').trim()) * valueMultiplier;
    const shares = Number(match[4].replaceAll(',', '').trim());
    if (!issuer || !cusip || !Number.isFinite(value) || !Number.isFinite(shares)) continue;
    const holding = rows.get(cusip);
    if (holding) { holding.value += value; holding.shares += shares; }
    else rows.set(cusip, { issuer, cusip, value, shares });
  }
  return rows;
}
async function filing13FTable(cik: string, accession: string): Promise<{ rows: Map<string, ThirteenFRow>; url: string }> {
  const compact = accession.replaceAll('-', '');
  const base = `https://www.sec.gov/Archives/edgar/data/${Number(cik)}/${compact}`;
  const index = await cached(`sec/13f/index/v1/${compact}`, 86400, () => getJSON<{ directory?: { item?: { name: string; type?: string; description?: string }[] } }>(`${base}/index.json`, { headers: { 'User-Agent': sec } }));
  const table = index.directory?.item?.find(item => /information table/i.test(`${item.type ?? ''} ${item.description ?? ''}`) && item.name.toLowerCase().endsWith('.xml'))
    ?? index.directory?.item?.find(item => /infotable|13f/i.test(item.name) && item.name.toLowerCase().endsWith('.xml') && !/primary_doc/i.test(item.name))
    ?? index.directory?.item?.find(item => item.name.toLowerCase().endsWith('.xml') && !/primary_doc/i.test(item.name));
  if (!table) throw new DataError(502, 'SEC filing has no readable 13F information table');
  const xml = await cached(`sec/13f/table/v1/${compact}`, 86400, () => getText(`${base}/${table.name}`, { headers: { 'User-Agent': sec }, timeout: 15000 }));
  const filingYear = 2000 + Number(/-(\d{2})-/.exec(accession)?.[1] ?? 0);
  const rows = parse13F(xml, filingYear);
  if (!rows.size) throw new DataError(502, 'SEC information table contained no parseable positions');
  return { rows, url: `${base}/${table.name}` };
}

// Routing

export function catalogJSON(base: string) {
  return {
    name: 'newswire-data', version: 1, description: 'Newswire market and economic data tools. Every result carries its source, URL and as-of time. GET {base}/v1/data/{path}?{params} with a bearer token; responses are JSON with a readable `text` field.',
    base, tools: tools.map(t => ({ name: t.name, path: t.path, description: t.description, parameters: schema(t) })),
  };
}
function schema(tool: Tool) {
  return { type: 'object', properties: Object.fromEntries(Object.entries(tool.params).map(([k, p]) => [k, { type: p.type, description: p.description, ...(p.enum ? { enum: p.enum } : {}) }])),
    required: Object.entries(tool.params).filter(([, p]) => p.required).map(([k]) => k), additionalProperties: false };
}

export async function runTool(name: string, raw: Record<string, unknown>, env: DataEnv): Promise<Payload> {
  const tool = tools.find(t => t.name === name);
  if (!tool) throw new DataError(404, `Unknown tool ${name}`);
  const args: Args = {};
  for (const [key, value] of Object.entries(raw)) {
    if (!(key in tool.params)) throw new DataError(400, `Unknown parameter ${key}`);
    if (value === null || value === undefined || value === '') continue;
    if (typeof value !== 'string' && typeof value !== 'number') throw new DataError(400, `Invalid ${key}`);
    args[key] = String(value);
  }
  let draft: Draft;
  try { draft = await tool.run(args, env); } catch (error) {
    if (error instanceof DataError) throw error;
    throw new DataError(502, `${name} failed: ${error instanceof Error ? error.message.slice(0, 200) : 'upstream error'}`);
  }
  const payload = { ...draft, as_of: draft.as_of ?? iso() };
  return { ...payload, text: render(payload) };
}

export async function dataRoute(path: string, params: URLSearchParams, env: DataEnv, origin: string): Promise<Response> {
  const rest = path.replace(/^\/v1\/data\/?/, '');
  if (rest === 'tools.json' || rest === 'tools') return Response.json(catalogJSON(origin));
  const args: Record<string, string> = {};
  for (const [key, value] of params) {
    if (key in args) throw new DataError(400, 'Repeated query parameter');
    args[key] = value;
  }
  const named = /^tool\/([a-z_]+)$/.exec(rest);
  if (named) return Response.json(await runTool(named[1], args, env));
  let tool = tools.find(t => t.path === rest);
  const series = /^series\/([A-Za-z0-9_.]{2,40})$/.exec(rest);
  const board = /^board\/([a-z]+)$/.exec(rest);
  if (!tool && series && series[1] !== 'search') { tool = tools.find(t => t.name === 'series'); args.id = series[1]; }
  if (!tool && board) { tool = tools.find(t => t.name === 'board'); args.name = board[1]; }
  if (!tool) throw new DataError(404, 'Unknown data route');
  return Response.json(await runTool(tool.name, args, env));
}

export async function mcpRoute(body: unknown, env: DataEnv, origin: string): Promise<Response> {
  const message = body as { jsonrpc?: string; id?: string | number | null; method?: string; params?: Record<string, unknown> } | null;
  if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string') return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid request' } }, { status: 400 });
  const reply = (result: unknown) => Response.json({ jsonrpc: '2.0', id: message.id ?? null, result });
  const fail = (code: number, text: string) => Response.json({ jsonrpc: '2.0', id: message.id ?? null, error: { code, message: text } });
  if (message.id === undefined) return new Response(null, { status: 202 });
  switch (message.method) {
    case 'initialize':
      return reply({ protocolVersion: String(message.params?.protocolVersion ?? '2025-06-18'), capabilities: { tools: { listChanged: false } }, serverInfo: { name: 'newswire-data', version: '1.0.0' },
        instructions: 'Newswire market, economic, filings and wire-search tools. Results include source, URL and as-of time; do not state figures that a tool did not return.' });
    case 'ping': return reply({});
    case 'tools/list': return reply({ tools: catalogJSON(origin).tools.map(t => ({ name: t.name, description: t.description, inputSchema: t.parameters })) });
    case 'tools/call': {
      const name = String(message.params?.name ?? '');
      try {
        const payload = await runTool(name, (message.params?.arguments ?? {}) as Record<string, unknown>, env);
        return reply({ content: [{ type: 'text', text: payload.text }], isError: false });
      } catch (error) {
        if (error instanceof DataError && error.status === 404 && error.message.startsWith('Unknown tool')) return fail(-32602, error.message);
        return reply({ content: [{ type: 'text', text: error instanceof Error ? error.message : 'Tool failed' }], isError: true });
      }
    }
    default: return fail(-32601, 'Method not found');
  }
}
