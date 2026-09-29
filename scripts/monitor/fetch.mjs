const agent = 'newswire-monitor/1.0 (personal news wire; contact via repository owner)';

export async function getJson(url, { headers = {}, timeout = 15000 } = {}) {
  const response = await fetch(url, { headers: { 'User-Agent': agent, Accept: 'application/json', ...headers }, signal: AbortSignal.timeout(timeout) });
  if (!response.ok) throw new Error(`${response.status} ${url}`);
  return response.json();
}

export async function getText(url, { headers = {}, timeout = 15000 } = {}) {
  const response = await fetch(url, { headers: { 'User-Agent': agent, ...headers }, signal: AbortSignal.timeout(timeout) });
  if (!response.ok) throw new Error(`${response.status} ${url}`);
  return response.text();
}

export async function quote(symbol, range = '1y') {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=${range}&interval=1d`;
  const result = (await getJson(url, { headers: { 'User-Agent': 'Mozilla/5.0' } })).chart?.result?.[0];
  if (!result?.meta) throw new Error(`No chart data for ${symbol}`);
  const closes = [];
  const stamps = [];
  const raw = result.indicators?.quote?.[0]?.close ?? [];
  raw.forEach((value, index) => { if (typeof value === 'number' && Number.isFinite(value)) { closes.push(value); stamps.push(result.timestamp[index] * 1000); } });
  const price = result.meta.regularMarketPrice;
  if (typeof price !== 'number' || !Number.isFinite(price) || closes.length < 2) throw new Error(`Incomplete chart data for ${symbol}`);
  const zone = result.meta.exchangeTimezoneName ?? 'America/New_York';
  const quotedMs = (result.meta.regularMarketTime ?? Math.floor(Date.now() / 1000)) * 1000;
  const session = day(quotedMs, zone);
  let previousIndex = stamps.length - 1;
  while (previousIndex >= 0 && day(stamps[previousIndex], zone) >= session) previousIndex -= 1;
  if (previousIndex < 0) throw new Error(`No prior session for ${symbol}`);
  const previousClose = closes[previousIndex];
  return {
    symbol,
    price,
    previousClose,
    changePercent: ((price - previousClose) / previousClose) * 100,
    high52: result.meta.fiftyTwoWeekHigh ?? Math.max(...closes),
    low52: result.meta.fiftyTwoWeekLow ?? Math.min(...closes),
    peakClose: Math.max(...closes),
    troughClose: Math.min(...closes),
    zone,
    session,
    quotedAt: new Date(quotedMs).toISOString(),
  };
}

export async function quotes(symbols, range = '1y') {
  const settled = await Promise.allSettled(symbols.map(symbol => quote(symbol, range)));
  const values = new Map();
  const failures = [];
  settled.forEach((entry, index) => entry.status === 'fulfilled' ? values.set(symbols[index], entry.value) : failures.push(`${symbols[index]}: ${entry.reason?.message ?? entry.reason}`));
  return { values, failures };
}

export async function fred(series) {
  const settled = await Promise.allSettled(series.map(async name => {
    const body = await getText(`https://fred.stlouisfed.org/graph/fredgraph.csv?id=${encodeURIComponent(name)}`, { headers: { Accept: 'text/csv' } });
    const lines = body.trim().split('\n');
    if (lines.length < 2 || !lines[0].includes(',')) throw new Error(`Unexpected FRED response for ${name}`);
    for (let index = lines.length - 1; index > 0; index -= 1) {
      const [date, raw] = lines[index].split(',');
      const value = Number(raw);
      if (Number.isFinite(value)) return { date: date.trim(), value };
    }
    throw new Error(`No numeric observations for ${name}`);
  }));
  const result = new Map();
  settled.forEach((entry, index) => result.set(series[index], entry.status === 'fulfilled' ? entry.value : null));
  return result;
}

export function day(ms, zone) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(ms));
}

export function marketSession(now = Date.now()) {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date(now));
  const get = type => parts.find(part => part.type === type)?.value ?? '';
  const weekday = get('weekday');
  const minutes = Number(get('hour')) * 60 + Number(get('minute'));
  if (['Sat', 'Sun'].includes(weekday)) return 'closed';
  if (minutes >= 570 && minutes < 960) return 'open';
  if (minutes >= 240 && minutes < 570) return 'premarket';
  if (minutes >= 960 && minutes < 1200) return 'afterhours';
  return 'closed';
}

export function signed(value, digits = 2) {
  return `${value >= 0 ? '+' : ''}${value.toFixed(digits)}`;
}

export function money(value) {
  return value >= 1000 ? value.toLocaleString('en-US', { maximumFractionDigits: 0 }) : value.toFixed(2);
}
