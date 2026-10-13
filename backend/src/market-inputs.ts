import { cached } from './quotes';
import { marketInstruments, type MarketInput } from './market-pulse';

export interface Bars { symbol: string; times: number[]; closes: number[]; live: { price: number; time: number } | null }

const minute = 60000, hour = 3600000, bar = 5 * minute;

function closeAt(series: Bars, t: number, live: boolean): { price: number; time: number } | null {
  // A 5-minute bar is known only once it has closed; the in-progress quote is used only for the live snapshot.
  if (live && series.live && series.live.time <= t + minute) return series.live;
  for (let i = series.times.length - 1; i >= 0; i -= 1) if (series.times[i] + bar <= t) return { price: series.closes[i], time: series.times[i] + bar };
  return null;
}

export function inputsAt(all: Bars[], t: number, live = false): MarketInput[] {
  return marketInstruments.map(spec => {
    const series = all.find(s => s.symbol === spec.symbol);
    const empty = { id: spec.id, label: spec.label, symbol: spec.symbol, unit: spec.unit, price: null, price_at: null, change_day: null, change_hour: null, status: 'unavailable' as const };
    if (!series) return empty;
    const scale = (value: number) => spec.unit === 'bp' && value > 20 ? value / 10 : value;
    const latest = closeAt(series, t, live), day = closeAt(series, t - 24 * hour, false), recent = closeAt(series, t - hour, false);
    if (!latest) return empty;
    const change = (from: { price: number } | null) => {
      if (!from) return null;
      const a = scale(from.price), b = scale(latest.price);
      return Math.round((spec.unit === 'bp' ? (b - a) * 100 : (b - a) / a * 100) * 100) / 100;
    };
    // Old prices (weekends, holidays, outages) describe no current condition; overseas closes stay relevant until the US session.
    const status = t - latest.time > spec.stale * hour ? 'stale' as const : 'live' as const;
    return { id: spec.id, label: spec.label, symbol: spec.symbol, unit: spec.unit, price: Math.round(scale(latest.price) * 10000) / 10000, price_at: new Date(latest.time).toISOString(),
      change_day: change(day), change_hour: change(recent), status };
  });
}

export async function loadBars(asOf: number, historyHours: number): Promise<Bars[]> {
  // Four extra days reach back past a weekend, so session markets compare against their previous close.
  const end = Math.ceil(asOf / minute) * minute, start = end - (historyHours + 24 + 96) * hour;
  const settled = await Promise.allSettled(marketInstruments.map(spec => cached(`pulse-bars/${encodeURIComponent(spec.symbol)}/${start}/${end}`, Date.now() - end > 10 * minute ? 3600 : 60, async () => {
    const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(spec.symbol)}?period1=${Math.floor(start / 1000)}&period2=${Math.floor(end / 1000)}&interval=5m&includePrePost=true`;
    const response = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; Newswire/1.0)', Accept: 'application/json' }, signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error(`Yahoo ${response.status}`);
    const result = ((await response.json()) as { chart?: { result?: { timestamp?: number[]; meta?: { regularMarketPrice?: number; regularMarketTime?: number }; indicators?: { quote?: { close?: (number | null)[] }[] } }[] } }).chart?.result?.[0];
    const times: number[] = [], closes: number[] = [];
    (result?.timestamp ?? []).forEach((stamp, i) => {
      const close = result?.indicators?.quote?.[0]?.close?.[i];
      if (typeof close === 'number' && Number.isFinite(close)) { times.push(stamp * 1000); closes.push(close); }
    });
    const price = result?.meta?.regularMarketPrice, time = result?.meta?.regularMarketTime;
    return { symbol: spec.symbol, times, closes, live: typeof price === 'number' && typeof time === 'number' ? { price, time: time * 1000 } : null } satisfies Bars;
  })));
  return settled.flatMap(entry => entry.status === 'fulfilled' ? [entry.value] : []);
}
