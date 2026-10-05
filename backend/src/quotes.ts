const agent = 'Mozilla/5.0 (compatible; Newswire/1.0)';
const aliases: Record<string, string> = {
  SPX: '^GSPC', IXIC: '^IXIC', DJI: '^DJI', RUT: '^RUT', ES: 'ES=F', NQ: 'NQ=F', VIX: '^VIX', UST10Y: '^TNX',
  BTC: 'BTC-USD', ETH: 'ETH-USD', SOL: 'SOL-USD', XRP: 'XRP-USD', DOGE: 'DOGE-USD',
};
const nicknames: Record<string, string> = { google: 'GOOGL', facebook: 'META' };
const suffixes = new Set(['inc', 'incorporated', 'corp', 'corporation', 'co', 'company', 'ltd', 'limited', 'plc', 'sa', 'ag', 'nv', 'se', 'holdings', 'holding', 'group', 'the', 'class', 'a', 'b', 'c', 'adr', 'common', 'stock', 'shares', 'lp', 'llc']);
const connectors = new Set(['of', '&', 'and']);
const breakers = new Set([
  'a', 'an', 'the', 'as', 'at', 'on', 'in', 'to', 'for', 'with', 'from', 'into', 'over', 'amid', 'after', 'before', 'by', 'but', 'or', 'if', 'is', 'are', 'was', 'be', 'its', 'it', 'how', 'why', 'what', 'who', 'when', 'where', 'this', 'that', 'these', 'those', 'new', 'says', 'say', 'said', 'will', 'may', 'could', 'would', 'should', 'can', 'up', 'down', 'off', 'out', 'vs', 'versus', 'than', 'more', 'most', 'less', 'not', 'no', 'all', 'about', 'just', 'here', 'there',
  'shares', 'share', 'stock', 'stocks', 'rise', 'rises', 'rose', 'fall', 'falls', 'fell', 'jump', 'jumps', 'drop', 'drops', 'slump', 'slumps', 'surge', 'surges', 'gain', 'gains', 'soar', 'soars', 'sink', 'sinks', 'plunge', 'plunges', 'rally', 'rallies', 'climb', 'climbs', 'slide', 'slides', 'tumble', 'tumbles', 'earnings', 'profit', 'revenue', 'sales', 'deal', 'plans', 'plan', 'report', 'reports', 'ceo', 'ipo', 'ai',
]);
const ignored = new Set(['us', 'u.s', 'uk', 'eu', 'un', 'fed', 'trump', 'biden', 'harris', 'wall', 'wall street', 'white house', 'congress', 'senate', 'treasury', 'china', 'europe', 'japan', 'target', 'block', 'gap', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday', 'january', 'february', 'march', 'april', 'june', 'july', 'august', 'september', 'october', 'november', 'december', 'bloomberg', 'reuters', 'cnbc', 'yahoo finance']);

export interface Mention { symbol: string; match: string }
export interface Quote {
  symbol: string; name: string; match?: string; currency: string; exchange: string; state: 'pre' | 'regular' | 'post' | 'closed';
  price: number; change: number; changePercent: number; previousClose: number; time: string;
  extended: { session: 'pre' | 'post'; price: number; change: number; changePercent: number; time: string } | null;
  points: number[]; extendedPoints: number[]; url: string;
}

async function cached<T>(key: string, ttl: number, load: () => Promise<T>): Promise<T> {
  const cache = (globalThis as unknown as { caches?: { default?: Cache } }).caches?.default;
  const url = `https://newswire-cache.internal/${key}`;
  const hit = await cache?.match(url).catch(() => undefined);
  if (hit) return hit.json() as Promise<T>;
  const value = await load();
  await cache?.put(url, new Response(JSON.stringify(value), { headers: { 'Cache-Control': `max-age=${ttl}`, 'Content-Type': 'application/json' } })).catch(() => undefined);
  return value;
}

async function yahoo(url: string): Promise<unknown> {
  const response = await fetch(url, { headers: { 'User-Agent': agent, Accept: 'application/json' }, signal: AbortSignal.timeout(4000) });
  if (!response.ok) throw new Error(`Yahoo ${response.status}`);
  return response.json();
}

const words = (value: string) => value.toLowerCase().replace(/[’']s\b/g, '').replace(/[^a-z0-9&\s-]/g, ' ').split(/\s+/).filter(Boolean);
const core = (value: string) => words(value).filter(word => !suffixes.has(word));

export function candidates(text: string): string[] {
  const found: string[] = [];
  const add = (tokens: string[]) => {
    while (tokens.length && connectors.has(tokens.at(-1)!.toLowerCase())) tokens.pop();
    for (let size = Math.min(4, tokens.length); size >= 1; size--) {
      if (connectors.has(tokens[size - 1].toLowerCase()) || (size === 1 && tokens.length > 1)) continue;
      const phrase = tokens.slice(0, size).join(' ').replace(/[’']s$/, '').replace(/[.,]$/, '');
      if (phrase && !found.includes(phrase)) found.push(phrase);
    }
  };
  for (const sentence of text.split(/(?<=[.!?:;])\s+|\n+|\s[-–—|]\s/)) {
    let run: string[] = [];
    for (const raw of sentence.split(/\s+/)) {
      const token = raw.replace(/^[("“‘'\[]+|[)"”’\],:;!?]+$/g, '');
      const lower = token.toLowerCase().replace(/[’']s$/, '').replace(/\.$/, '');
      const capital = /^[A-Z0-9][A-Za-z0-9&.’'-]*$/.test(token) && /[A-Za-z]/.test(token);
      if (run.length && connectors.has(lower)) { run.push(token); continue; }
      if (capital && !breakers.has(lower)) { run.push(token); continue; }
      if (run.length) add(run);
      run = [];
    }
    if (run.length) add(run);
  }
  return found.filter(phrase => !ignored.has(phrase.toLowerCase().replace(/\.$/, '')) && phrase.length > 1 && !/^\d+$/.test(phrase));
}

export function accepts(phrase: string, name: string): boolean {
  const said = core(phrase);
  const named = core(name);
  if (!said.length || !named.length) return false;
  const generic = words(name).some(word => ['holding', 'holdings', 'group', 'company', 'co', 'trust', 'bancorp', 'financial'].includes(word));
  if (said.length === 1 && generic && !/^[A-Z0-9&]{2,}$/.test(phrase.trim())) return false;
  if (said.length === named.length && said.every((word, i) => word === named[i])) return true;
  return named.length >= 2 && said.length > named.length && named.every((word, i) => word === said[i]);
}

interface SearchQuote { symbol?: string; shortname?: string; longname?: string; quoteType?: string }

async function lookup(phrase: string): Promise<string | null> {
  const nickname = nicknames[phrase.toLowerCase()];
  if (nickname) return nickname;
  return cached(`search/v2/${encodeURIComponent(phrase.toLowerCase())}`, 604800, async () => {
    const url = `https://query2.finance.yahoo.com/v1/finance/search?q=${encodeURIComponent(phrase)}&quotesCount=5&newsCount=0&listsCount=0&enableFuzzyQuery=false`;
    const data = await yahoo(url) as { quotes?: SearchQuote[] };
    const hit = (data.quotes ?? []).find(quote => quote.symbol && quote.quoteType === 'EQUITY' && !/\.(?:HA|F|DU|MU|SG|BE|HM|TWO|BA|MX|VI|NE)$/.test(quote.symbol) && [quote.longname, quote.shortname].some(name => name && accepts(phrase, name)));
    return hit?.symbol ?? null;
  }).catch(() => null);
}

export async function resolve(text: string, limit = 4): Promise<Mention[]> {
  const explicit: Mention[] = [];
  for (const match of text.matchAll(/\((?:NYSE|NASDAQ|Nasdaq|NYSE American|NYSEArca|TSX|LSE|OTC)\s*:\s*([A-Z][A-Z.]{0,6})\)|\$([A-Z]{1,5})\b|\(([A-Z]{2,5})\)/g)) {
    const symbol = match[1] ?? match[2] ?? match[3];
    if (symbol && !['CEO', 'IPO', 'GDP', 'CPI', 'ETF', 'SEC', 'FDA', 'AI', 'EU', 'UK', 'US'].includes(symbol) && !explicit.some(item => item.symbol === symbol)) explicit.push({ symbol, match: symbol });
  }
  const phrases = candidates(text).slice(0, 12);
  const results = await Promise.all(phrases.map(async phrase => ({ phrase, symbol: await lookup(phrase) })));
  const mentions = [...explicit];
  const covered: string[] = [];
  for (const { phrase, symbol } of results) {
    if (!symbol || covered.some(taken => taken.startsWith(phrase) || phrase.startsWith(taken))) continue;
    covered.push(phrase);
    if (!mentions.some(item => item.symbol === symbol)) mentions.push({ symbol, match: phrase });
  }
  return mentions.slice(0, limit);
}

interface Chart {
  meta: Record<string, unknown> & { currentTradingPeriod?: Record<'pre' | 'regular' | 'post', { start: number; end: number }>; tradingPeriods?: unknown };
  timestamp?: number[];
  indicators?: { quote?: { close?: (number | null)[] }[] };
}

const round = (value: number) => Math.round(value * 10000) / 10000;
const iso = (seconds: number) => new Date(seconds * 1000).toISOString();

export function shape(chart: Chart, now = Date.now() / 1000): Omit<Quote, 'match'> | null {
  const meta = chart.meta;
  const price = meta.regularMarketPrice as number;
  const previous = (meta.previousClose ?? meta.chartPreviousClose) as number;
  if (typeof price !== 'number' || typeof previous !== 'number' || !previous) return null;
  const periods = meta.currentTradingPeriod;
  const inside = (period?: { start: number; end: number }) => !!period && now >= period.start && now < period.end;
  const state = inside(periods?.regular) ? 'regular' : inside(periods?.pre) ? 'pre' : inside(periods?.post) ? 'post' : 'closed';
  const regularTime = (meta.regularMarketTime as number) ?? now;
  const nested = meta.tradingPeriods as { regular?: { start: number; end: number }[][] } | undefined;
  const session = nested?.regular?.flat().at(-1) ?? periods?.regular;
  const stamps = chart.timestamp ?? [];
  const closes = chart.indicators?.quote?.[0]?.close ?? [];
  const regular: number[] = [];
  const extended: number[] = [];
  let tail: { price: number; time: number } | null = null;
  stamps.forEach((stamp, i) => {
    const close = closes[i];
    if (typeof close !== 'number' || !Number.isFinite(close)) return;
    if (session && stamp >= session.start && stamp < session.end) regular.push(close);
    else if (session && stamp >= session.end) extended.push(close);
    if (stamp > regularTime + 30) tail = { price: close, time: stamp };
  });
  const last = tail as { price: number; time: number } | null;
  const extendedSession: 'pre' | 'post' = last && periods?.pre && last.time >= periods.pre.start && last.time < periods.pre.end ? 'pre' : 'post';
  const hasExtended = meta.hasPrePostMarketData === true && last !== null && state !== 'regular' && last.price !== price;
  const thin = (values: number[], max = 60) => values.length <= max ? values : Array.from({ length: max }, (_, i) => values[Math.round(i * (values.length - 1) / (max - 1))]);
  const symbol = String(meta.symbol);
  return {
    symbol,
    name: String(meta.shortName ?? meta.longName ?? symbol),
    currency: String(meta.currency ?? ''),
    exchange: String(meta.fullExchangeName ?? meta.exchangeName ?? ''),
    state,
    price: round(price),
    change: round(price - previous),
    changePercent: round((price - previous) / previous * 100),
    previousClose: round(previous),
    time: iso(regularTime),
    extended: hasExtended && last ? { session: extendedSession, price: round(last.price), change: round(last.price - price), changePercent: round((last.price - price) / price * 100), time: iso(last.time) } : null,
    points: thin(regular).map(round),
    extendedPoints: hasExtended && extendedSession === 'post' ? thin(extended, 20).map(round) : [],
    url: `https://finance.yahoo.com/quote/${encodeURIComponent(symbol)}`,
  };
}

export async function quote(symbol: string): Promise<Omit<Quote, 'match'> | null> {
  const target = aliases[symbol.toUpperCase()] ?? symbol;
  return cached(`quote/${encodeURIComponent(target)}`, 20, async () => {
    const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(target)}?range=1d&interval=5m&includePrePost=true`;
    const data = await yahoo(url) as { chart?: { result?: Chart[] } } | null;
    const chart = data?.chart?.result?.[0];
    return chart?.meta ? shape(chart) : null;
  }).catch(() => null);
}

export async function quotes(mentions: Mention[]): Promise<Quote[]> {
  const loaded = await Promise.all(mentions.map(async (mention): Promise<Quote | null> => {
    const value = await quote(mention.symbol);
    if (!value) return null;
    return mention.match === mention.symbol ? { ...value, symbol: mention.symbol } : { ...value, symbol: mention.symbol, match: mention.match };
  }));
  return loaded.filter((value): value is Quote => value !== null);
}
