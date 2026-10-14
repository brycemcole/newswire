export const researchSymbols = ['SPY', 'QQQ', 'IWM', 'DIA'] as const;

export async function researchPrices(symbol: string, now = Date.now()) {
  if (!(researchSymbols as readonly string[]).includes(symbol)) throw new Error('Unsupported research symbol');
  const url = new URL(`https://query1.finance.yahoo.com/v8/finance/chart/${symbol}`);
  for (const [key, value] of Object.entries({ period1: Math.floor((now - 7 * 86400000) / 1000), period2: Math.floor(now / 1000), interval: '5m', includePrePost: 'true' })) url.searchParams.set(key, String(value));
  const response = await fetch(url, { headers: { 'User-Agent': 'NewswireResearch/1.0', Accept: 'application/json' }, signal: AbortSignal.timeout(10000) });
  if (!response.ok) throw new Error(`Target prices HTTP ${response.status}`);
  const payload = await response.json() as any;
  if (payload.chart?.error || !payload.chart?.result?.[0]) throw new Error('Target prices unavailable');
  const chart = payload.chart.result[0];
  if (chart.meta?.symbol !== symbol) throw new Error('Target price symbol mismatch');
  return { url: url.href, retrieved_at: new Date().toISOString(), payload };
}

export function targetPrices(archive: any, now: number) {
  const chart = archive?.payload?.chart?.result?.[0];
  const times = chart?.timestamp ?? [], closes = chart?.indicators?.quote?.[0]?.close ?? [];
  const zone = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' });
  const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/New_York', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  const today = zone.format(new Date(now));
  const bars = times.map((time: number, i: number) => ({ start: time * 1000, end: (time + 300) * 1000, close: closes[i] }))
    .filter((bar: { start: number; end: number; close: number }) => Number.isFinite(bar.close) && bar.close > 0 && bar.end <= now)
    .sort((a: { start: number }, b: { start: number }) => a.start - b.start);
  const recent = bars.at(-1);
  const previous = bars.filter((bar: { start: number; end: number }) => zone.format(new Date(bar.start)) < today && ['16:00', '13:00'].includes(clock.format(new Date(bar.end)))).at(-1);
  return { price: recent?.close ?? null, price_at: recent ? new Date(recent.end).toISOString() : null,
    previous_close: previous?.close ?? null, previous_close_at: previous ? new Date(previous.end).toISOString() : null,
    source: archive.url, observed_at: archive.retrieved_at };
}
