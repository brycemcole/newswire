import { cached } from './quotes';
import { basketSymbols, bellwethers, marketInstruments, type MarketInput } from './market-pulse';
import { sessionFor } from './forecast';

export interface Bars { symbol: string; times: number[]; closes: number[]; live: { price: number; time: number } | null }

const minute = 60000, hour = 3600000, bar = 5 * minute;

// The newest observation known at t: a closed bar, or the live quote when the snapshot is live and the quote is not from the future.
function closeAt(series: Bars, t: number, live: boolean): { price: number; time: number } | null {
  let closed: { price: number; time: number } | null = null;
  for (let i = series.times.length - 1; i >= 0; i -= 1) if (series.times[i] + bar <= t) { closed = { price: series.closes[i], time: series.times[i] + bar }; break; }
  const quote = live && series.live && series.live.time <= t + minute ? series.live : null;
  return quote && (!closed || quote.time >= closed.time) ? quote : closed;
}

const etParts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' });

// New York calendar date ("YYYY-MM-DD") and minutes after midnight for an instant.
function nyClock(ms: number): { date: string; minutes: number } {
  const p = Object.fromEntries(etParts.formatToParts(new Date(ms)).map(part => [part.type, part.value]));
  return { date: `${p.year}-${p.month.padStart(2, '0')}-${p.day.padStart(2, '0')}`, minutes: Number(p.hour) * 60 + Number(p.minute) };
}

// Most recent NYSE 4:00 PM (or early 1:00 PM) close at or before t. Uses the same calendar as the forecast sessions, so weekends, holidays and early closes match.
export function lastCashClose(t: number): number {
  let day = Date.parse(`${nyClock(t).date}T12:00:00Z`);
  for (let i = 0; i < 12; i += 1, day -= 24 * hour) {
    const session = sessionFor(new Date(day).toISOString().slice(0, 10));
    if (session && session.close <= t) return session.close;
  }
  return t - 24 * hour;
}

// Weekday 4:00 AM to 9:30 AM New York time on an NYSE session day, the pre-market session.
function inPremarket(t: number): boolean {
  const { date, minutes } = nyClock(t);
  return sessionFor(date) !== null && minutes >= 240 && minutes < 570;
}

// Bellwether pre-market moves against the last cash close. Only members with a bar newer than that close, within 30 minutes, count.
function premarketInput(all: Bars[], spec: (typeof marketInstruments)[number], t: number, live: boolean): MarketInput {
  const cash = lastCashClose(t), members: NonNullable<MarketInput['members']> = [];
  let newest = 0;
  for (const symbol of basketSymbols) {
    const series = all.find(s => s.symbol === symbol);
    const latest = series ? closeAt(series, t, live) : null, base = series ? closeAt(series, cash, false) : null;
    if (!latest || !base || base.price <= 0 || latest.time <= cash || t - latest.time > 30 * minute) continue;
    members.push({ symbol, name: bellwethers[symbol].name, change: Math.round((latest.price - base.price) / base.price * 100 * 100) / 100 });
    newest = Math.max(newest, latest.time);
  }
  const status = inPremarket(t) && members.length >= 5 ? 'live' as const : 'stale' as const;
  return { id: spec.id, label: spec.label, symbol: spec.symbol, unit: spec.unit, price: null, price_at: newest ? new Date(newest).toISOString() : null, change_day: null, change_hour: null, status,
    ...(status === 'live' ? { members } : {}) };
}

export function inputsAt(all: Bars[], t: number, live = false): MarketInput[] {
  return marketInstruments.map((spec): MarketInput => {
    if (spec.kind === 'basket') return premarketInput(all, spec, t, live);
    const series = all.find(s => s.symbol === spec.symbol);
    const empty: MarketInput = { id: spec.id, label: spec.label, symbol: spec.symbol, unit: spec.unit, price: null, price_at: null, change_day: null, change_hour: null, status: 'unavailable' };
    if (!series) return empty;
    if (spec.kind === 'ratio') {
      const denominator = all.find(s => s.symbol === spec.denominator);
      const top = closeAt(series, t, false), bottom = denominator ? closeAt(denominator, t, false) : null;
      if (!top || !bottom || bottom.price <= 0) return empty;
      const fresh = t - top.time <= spec.stale * hour && t - bottom.time <= spec.stale * hour;
      return { ...empty, price: Math.round(top.price / bottom.price * 1000) / 1000, price_at: new Date(Math.min(top.time, bottom.time)).toISOString(), status: fresh ? 'live' : 'stale' };
    }
    if (spec.kind === 'drawdown') {
      const latest = closeAt(series, t, live);
      let baselineClose = lastCashClose(t);
      for (let i = 0; i < spec.sessions!; i += 1) baselineClose = lastCashClose(baselineClose - minute);
      const base = closeAt(series, baselineClose, false);
      if (!latest) return empty;
      const value = base && base.price > 0 ? Math.round((latest.price - base.price) / base.price * 100 * 100) / 100 : null;
      return { ...empty, price: Math.round(latest.price * 10000) / 10000, price_at: new Date(latest.time).toISOString(), change_day: value,
        status: value === null ? 'unavailable' : t - latest.time > spec.stale * hour ? 'stale' : 'live' };
    }
    const latest = closeAt(series, t, live), recent = closeAt(series, t - hour, false);
    const day = closeAt(series, spec.baseline === 'cash_close' ? lastCashClose(t) : t - 24 * hour, false);
    if (!latest) return empty;
    const change = (from: { price: number } | null) => {
      if (!from || from.price <= 0) return null;
      return Math.round((latest.price - from.price) / from.price * 100 * 100) / 100;
    };
    const changeDay = change(day);
    // Old prices (weekends, holidays, outages) describe no current condition; overseas closes stay relevant until the US session.
    // Without a baseline close the price is kept for inspection but cannot describe a move, so it is not live.
    const status = changeDay === null ? 'unavailable' as const : t - latest.time > spec.stale * hour ? 'stale' as const : 'live' as const;
    return { id: spec.id, label: spec.label, symbol: spec.symbol, unit: spec.unit, price: Math.round(latest.price * 10000) / 10000, price_at: new Date(latest.time).toISOString(),
      change_day: changeDay, change_hour: change(recent), status };
  });
}

export async function loadBars(asOf: number, historyHours: number): Promise<Bars[]> {
  // Seven extra days reach back past a weekend, so session markets and the 3-session drawdown have their prior closes.
  const end = Math.ceil(asOf / minute) * minute, start = end - (historyHours + 24 + 168) * hour;
  const symbols = [...new Set([...marketInstruments.flatMap(spec => spec.kind === 'basket' ? [] : spec.denominator ? [spec.symbol, spec.denominator] : [spec.symbol]), ...basketSymbols])];
  const settled = await Promise.allSettled(symbols.map(symbol => cached(`pulse-bars/${encodeURIComponent(symbol)}/${start}/${end}`, Date.now() - end > 10 * minute ? 3600 : 60, async () => {
    const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?period1=${Math.floor(start / 1000)}&period2=${Math.floor(end / 1000)}&interval=5m&includePrePost=true`;
    const response = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; Newswire/1.0)', Accept: 'application/json' }, signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error(`Yahoo ${response.status}`);
    const result = ((await response.json()) as { chart?: { result?: { timestamp?: number[]; meta?: { regularMarketPrice?: number; regularMarketTime?: number }; indicators?: { quote?: { close?: (number | null)[] }[] } }[] } }).chart?.result?.[0];
    const times: number[] = [], closes: number[] = [];
    (result?.timestamp ?? []).forEach((stamp, i) => {
      const close = result?.indicators?.quote?.[0]?.close?.[i];
      if (typeof close === 'number' && Number.isFinite(close)) { times.push(stamp * 1000); closes.push(close); }
    });
    const price = result?.meta?.regularMarketPrice, time = result?.meta?.regularMarketTime;
    return { symbol, times, closes, live: typeof price === 'number' && typeof time === 'number' ? { price, time: time * 1000 } : null } satisfies Bars;
  })));
  return settled.flatMap(entry => entry.status === 'fulfilled' ? [entry.value] : []);
}
