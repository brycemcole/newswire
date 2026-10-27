import { sessionFor } from './forecast';
import type { Quote } from './quotes';

export interface MarketDataEnv { DB: D1Database; TWELVE_DATA_API_KEY?: string; MASSIVE_API_KEY?: string; FMP_API_KEY?: string }
type Provider = 'twelve' | 'massive' | 'fmp';
const pending = new WeakMap<D1Database, Map<string, Promise<unknown>>>();
const dateInNY = (time: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(time));

function previousSession(date: string) {
  const day = new Date(`${date}T12:00:00Z`);
  for (let i = 0; i < 12; i++) {
    day.setUTCDate(day.getUTCDate() - 1);
    const session = sessionFor(day.toISOString().slice(0, 10));
    if (session) return session;
  }
  return null;
}

export function quoteStatus(time: number, now = Date.now()): 'current' | 'closed' | 'stale' {
  if (!Number.isFinite(time) || time > now + 60000) return 'stale';
  const date = dateInNY(now), today = sessionFor(date);
  if (today && now >= today.open && now < today.close) return now - time <= 300000 && time >= today.open ? 'current' : 'stale';
  const completed = today && now >= today.close ? today : previousSession(date);
  return completed && time >= completed.close - 300000 ? 'closed' : 'stale';
}

export async function providerData<T>(env: MarketDataEnv, provider: Provider, resource: string, path: string, ttl: number): Promise<{ data: T; fetchedAt: string } | null> {
  const key = provider === 'twelve' ? env.TWELVE_DATA_API_KEY : provider === 'massive' ? env.MASSIVE_API_KEY : env.FMP_API_KEY;
  if (!key) return null;
  let requests = pending.get(env.DB);
  if (!requests) { requests = new Map(); pending.set(env.DB, requests); }
  const id = `${provider}/${resource}`;
  if (requests.has(id)) return requests.get(id) as Promise<{ data: T; fetchedAt: string } | null>;
  const request = (async () => {
    const now = Date.now();
    const hit = await env.DB.prepare('SELECT body, fetched_at FROM market_data_cache WHERE provider = ? AND resource = ? AND expires_at > ?').bind(provider, resource, now).first<{ body: string; fetched_at: number }>();
    if (hit) return { data: JSON.parse(hit.body) as T, fetchedAt: new Date(hit.fetched_at).toISOString() };
    await env.DB.prepare('DELETE FROM market_data_cache WHERE expires_at <= ?').bind(now).run();
    const minute = Math.floor(now / 60000), day = new Date(now).toISOString().slice(0, 10);
    const allowance = await env.DB.prepare(`INSERT INTO market_data_usage (provider, day, minute, minute_used, day_used) VALUES (?, ?, ?, 1, 1)
      ON CONFLICT(provider) DO UPDATE SET day = excluded.day, minute = excluded.minute,
      minute_used = CASE WHEN minute = excluded.minute THEN minute_used + 1 ELSE 1 END,
      day_used = CASE WHEN day = excluded.day THEN day_used + 1 ELSE 1 END
      WHERE (day != excluded.day OR day_used < ?) AND (minute != excluded.minute OR minute_used < ?)
      RETURNING day_used`).bind(provider, day, minute, provider === 'twelve' ? 760 : provider === 'fmp' ? 230 : 5000, provider === 'twelve' ? 7 : 4).first();
    if (!allowance) return null;
    try {
      const url = new URL(path, provider === 'twelve' ? 'https://api.twelvedata.com' : provider === 'fmp' ? 'https://financialmodelingprep.com' : 'https://api.massive.com');
      const headers: Record<string, string> = { Accept: 'application/json' };
      if (provider !== 'massive') url.searchParams.set('apikey', key);
      else headers.Authorization = `Bearer ${key}`;
      const response = await fetch(url, { headers, signal: AbortSignal.timeout(4500) });
      if (!response.ok) return null;
      const data = await response.json() as T & { status?: string; next_url?: string; 'Error Message'?: string };
      if (!data || data.status === 'error' || data.status === 'ERROR' || data.status === 'NOT_AUTHORIZED' || data['Error Message']) return null;
      if (provider === 'massive' && data.next_url) data.next_url = 'available';
      const fetchedAt = Date.now();
      await env.DB.prepare('INSERT INTO market_data_cache (provider, resource, body, fetched_at, expires_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(provider, resource) DO UPDATE SET body = excluded.body, fetched_at = excluded.fetched_at, expires_at = excluded.expires_at')
        .bind(provider, resource, JSON.stringify(data), fetchedAt, fetchedAt + ttl * 1000).run();
      return { data, fetchedAt: new Date(fetchedAt).toISOString() };
    } catch { return null; }
  })().catch(() => null).finally(() => requests!.delete(id));
  requests.set(id, request);
  return request;
}

export function twelveQuote(data: Record<string, unknown>, symbol: string, fetchedAt: string, now = Date.now()): Omit<Quote, 'match'> | null {
  const numeric = (value: unknown) => typeof value === 'number' || typeof value === 'string' && value.trim() !== '' ? Number(value) : NaN;
  const price = numeric(data.close), previous = numeric(data.previous_close);
  const time = numeric(data.last_quote_at ?? data.timestamp) * 1000;
  if (data.symbol !== symbol || !['NASDAQ', 'NYSE', 'NYSE American', 'NYSE ARCA', 'NYSEARCA', 'CBOE'].includes(String(data.exchange)) || data.currency !== 'USD') return null;
  if (![price, previous, time].every(Number.isFinite) || price <= 0 || previous <= 0 || time > now + 60000) return null;
  const date = typeof data.datetime === 'string' ? data.datetime.slice(0, 10) : '';
  const session = sessionFor(date);
  if (!session || dateInNY(time) !== date || time < session.open || time > session.close + 60000) return null;
  const current = sessionFor(dateInNY(now));
  const round = (n: number) => Math.round(n * 10000) / 10000;
  return { symbol, name: String(data.name ?? symbol), currency: 'USD', exchange: String(data.exchange),
    state: current && now >= current.open && now < current.close ? 'regular' : 'closed',
    price: round(price), previousClose: round(previous), change: round(price - previous), changePercent: round((price - previous) / previous * 100),
    time: new Date(time).toISOString(), extended: null, points: [], extendedPoints: [], url: `https://twelvedata.com/stocks/${encodeURIComponent(symbol)}`,
    source: 'Twelve Data', fetchedAt, dataStatus: quoteStatus(time, now) };
}

export async function twelve(env: MarketDataEnv, symbol: string) {
  if (!/^[A-Z]{1,5}(?:-[A-Z])?$/.test(symbol)) return null;
  const result = await providerData<Record<string, unknown>>(env, 'twelve', `quote/${symbol}`, `/quote?symbol=${encodeURIComponent(symbol.replace('-', '.'))}`, 120);
  return result ? twelveQuote(result.data, symbol.replace('-', '.'), result.fetchedAt) : null;
}

export interface OptionContract { ticker: string; underlying_ticker: string; contract_type: string; expiration_date: string; strike_price: number; shares_per_contract?: number; exercise_style?: string }
export async function optionContracts(env: MarketDataEnv, symbol: string, expiration?: string) {
  const query = new URLSearchParams({ underlying_ticker: symbol, expired: 'false', limit: '100', sort: 'expiration_date', order: 'asc' });
  if (expiration) query.set('expiration_date', expiration);
  return providerData<{ results?: OptionContract[]; next_url?: string }>(env, 'massive', `options/${symbol}/${expiration ?? 'next'}`, `/v3/reference/options/contracts?${query}`, 900);
}
