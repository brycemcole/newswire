import { sessionFor } from './forecast';

// Preset stock screens. Invariants:
//  - A row is shown only when the field its ranking needs is present and temporally valid; everything else is counted as excluded, with the reason.
//  - Observation time (newest quote or bar used), fetch time and computation time are separate; as_of is the newest observation included.
//  - The candidate pool is stated in the note. A screen ranks the pool, not the whole market.
//  - A multi-month return needs a baseline bar near the start of the window; a recent listing is excluded, never shown as a smaller window.
//  - Session boundaries come from the existing exchange calendar (holidays and early closes included).

const day = 86400;
const newYork = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' });

/** The most recent NYSE session that has already closed, in epoch seconds. */
export function lastCompletedSession(now = Date.now()): { date: string; open: number; close: number } {
  let cursor = now;
  for (let i = 0; i < 12; i++, cursor -= day * 1000) {
    const date = newYork.format(new Date(cursor));
    const session = sessionFor(date);
    if (session && session.close <= now) return { date, open: session.open / 1000, close: session.close / 1000 };
  }
  throw new Error('Unable to resolve the last NYSE session');
}

export interface Excluded { reason: string; count: number }
export function tally(reasons: string[]): Excluded[] {
  const counts = new Map<string, number>();
  for (const reason of reasons) counts.set(reason, (counts.get(reason) ?? 0) + 1);
  return [...counts].map(([reason, count]) => ({ reason, count }));
}

export interface Return { change: number; from: number; to: number; fromPrice: number; toPrice: number }
export type ReturnResult = { ok: true; value: Return } | { ok: false; reason: string };

/** Return over the span of daily bars, or why the bars cannot support it. */
export function windowReturn(timestamps: number[], closes: (number | null)[], now: number, spanDays = 91, session = lastCompletedSession(now)): ReturnResult {
  const bars = timestamps.flatMap((time, i) => typeof closes[i] === 'number' && Number.isFinite(closes[i]) && closes[i]! > 0 ? [{ time, close: closes[i]! }] : []);
  if (bars.length < 2) return { ok: false, reason: 'no price history' };
  const last = bars[bars.length - 1], first = bars[0];
  // The newest bar must belong to the latest completed session or later; an older bar is a stale quote, not a current price.
  if (last.time < session.open - 60) return { ok: false, reason: 'stale prices' };
  // The oldest bar must sit near the start of the window; a younger listing would otherwise be ranked on a shorter period.
  if (last.time - first.time < (spanDays - 6) * day) return { ok: false, reason: 'under 3 months of history' };
  return { ok: true, value: { change: (last.close - first.close) / first.close * 100, from: first.time, to: last.time, fromPrice: first.close, toPrice: last.close } };
}

export interface Rating { score: number; label: string }
/** Yahoo's consensus is text such as "1.8 - Buy" on a 1 (strong buy) to 5 (sell) scale. */
export function parseRating(value: unknown): Rating | null {
  if (typeof value !== 'string') return null;
  const match = /^\s*([1-5](?:\.\d+)?)\s*-\s*(.+?)\s*$/.exec(value);
  return match ? { score: Number(match[1]), label: match[2] } : null;
}

export interface Earnings { at: number; start: number | null; end: number | null }
export type EarningsResult = { ok: true; value: Earnings } | { ok: false; reason: string };
/** A report date inside [now, now + days]. Yahoo keeps the last report's timestamp until the next is scheduled, so a past one is not an upcoming date. */
export function upcomingEarnings(quote: Record<string, unknown>, now: number, days: number): EarningsResult {
  const num = (value: unknown) => typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null;
  const at = num(quote.earningsTimestamp) ?? num(quote.earningsTimestampStart);
  if (at === null) return { ok: false, reason: 'no earnings date' };
  const seconds = now / 1000;
  if (at < seconds) return { ok: false, reason: 'last report only, next date not set' };
  if (at > seconds + days * day) return { ok: false, reason: 'after window' };
  return { ok: true, value: { at, start: num(quote.earningsTimestampStart), end: num(quote.earningsTimestampEnd) } };
}
