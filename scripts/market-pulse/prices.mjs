const zone = 'America/New_York';
const dateFormat = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' });
const timeFormat = new Intl.DateTimeFormat('en-GB', { timeZone: zone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const round = n => Math.round(n * 10000) / 10000;
const percent = (price, reference) => reference > 0 && Number.isFinite(price) ? round((price / reference - 1) * 100) : null;

export function barsFromChart(archive) {
  const chart = archive?.payload?.chart?.result?.[0];
  if (!chart) return [];
  const q = chart.indicators?.quote?.[0] ?? {};
  return (chart.timestamp ?? []).map((stamp, i) => ({ start: stamp * 1000, end: (stamp + 300) * 1000,
    open: q.open?.[i], close: q.close?.[i], low: q.low?.[i], high: q.high?.[i] }))
    .filter(b => Number.isFinite(b.close) && b.close > 0).sort((a, b) => a.start - b.start);
}

export function priceComparison(archive, asOf) {
  const cutoff = Date.parse(asOf), target = dateFormat.format(new Date(cutoff));
  const bars = barsFromChart(archive);
  const date = b => dateFormat.format(new Date(b.start));
  const time = b => timeFormat.format(new Date(b.start));
  const prior = bars.filter(b => date(b) < target && time(b) === '15:55').at(-1);
  const before = bars.filter(b => b.end <= cutoff && date(b) === target).at(-1);
  const usable = before && cutoff - before.end <= 15 * 60000 ? before : null;
  const regular = bars.filter(b => date(b) === target && time(b) >= '09:30' && time(b) < '16:00');
  const openBar = regular.find(b => time(b) === '09:30');
  const closeBar = regular.find(b => time(b) === '15:55');
  const retrieved = Date.parse(archive?.retrieved_at);
  const close = closeBar && closeBar.end <= retrieved ? closeBar : null;
  const after = bars.filter(b => date(b) === target && b.start >= cutoff && time(b) < '16:00' && b.end <= retrieved);
  const lows = after.map(b => b.low).filter(n => Number.isFinite(n) && n > 0);
  return { source: archive?.url ?? null, retrieved_at: archive?.retrieved_at ?? null,
    provenance: 'Historical Yahoo 5-minute bars downloaded after the session; not an archived live quote feed. Bar ends must precede the cutoff. US equity-session comparison; crude uses the same clock, not settlement.',
    status: !bars.length ? 'unavailable' : !usable ? 'no_fresh_cutoff_bar' : !close ? 'session_incomplete' : 'available',
    prior_equity_session_close: prior ? { at: new Date(prior.end).toISOString(), price: prior.close } : null,
    at_cutoff: usable ? { at: new Date(usable.end).toISOString(), price: usable.close } : null,
    regular_open: openBar && openBar.start <= retrieved ? openBar.open : null,
    regular_close: close?.close ?? null,
    pre_cutoff_change_pct: usable && prior ? percent(usable.close, prior.close) : null,
    cutoff_to_close_pct: usable && close ? percent(close.close, usable.close) : null,
    open_to_close_pct: openBar && close ? percent(close.close, openBar.open) : null,
    prior_close_to_close_pct: prior && close ? percent(close.close, prior.close) : null,
    worst_after_cutoff_pct: usable && lows.length ? percent(Math.min(...lows), usable.close) : null };
}

export async function fetchPrices(asOf, symbols) {
  const day = dateFormat.format(new Date(asOf));
  const start = Date.parse(`${day}T00:00:00Z`) - 4 * 86400000;
  const end = Math.min(Date.now(), Date.parse(`${day}T00:00:00Z`) + 86400000);
  const entries = await Promise.all(symbols.map(async symbol => {
    const url = new URL(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}`);
    for (const [k, v] of Object.entries({ period1: Math.floor(start / 1000), period2: Math.floor(end / 1000), interval: '5m', includePrePost: 'true' })) url.searchParams.set(k, String(v));
    try {
      const response = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      if (payload.chart?.error) throw new Error(payload.chart.error.description);
      return [symbol, { retrieved_at: new Date().toISOString(), url: String(url), payload }];
    } catch (error) { return [symbol, { error: error.message }]; }
  }));
  return Object.fromEntries(entries);
}
