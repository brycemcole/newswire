// Deterministic headline relevance, used only for stories the classifier could not read this run.
// It is deliberately narrow: a story publishes when it names a held or watched symbol, or when a
// trusted publisher's title matches a topic rule. Everything else waits for the classifier.
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { getJson } from './fetch.mjs';
import { duplicateMatches } from './headline-dedupe.mjs';

// Title rules per watchlist topic. Each needs a concrete event word, not just a subject.
export const topicRules = {
  'us-market-movers': [
    /\b(Fed|Federal Reserve|FOMC|Powell)\b.*\b(rates?|cuts?|hikes?|holds?|raises?|lowers?|decision|minutes)\b/i,
    /\b(CPI|PCE|inflation|jobs report|payrolls|unemployment rate|jobless claims|GDP|retail sales|ISM)\b.*\b(rises?|rose|falls?|fell|jumps?|slows?|slowed|cools?|cooled|accelerates?|beats?|miss(es)?|unexpectedly|\d+(\.\d+)?%)/i,
  ],
  'market-analysis': [
    /\b(stocks?|S&P 500|Nasdaq|Dow|Russell 2000|Treasury yields?|bond yields?|oil prices?|crude|dollar|bitcoin)\b.*\b(fall|fell|drop|slide|slump|tumble|sink|plunge|rally|rallies|surge|soar|jump|climb|rise|rose|gain|record|sell-?off|rout)/i,
  ],
  tariffs: [/\b(tariffs?|import dut(y|ies)|export controls?|trade (deal|war|truce))\b/i],
  'credit-and-banking': [/\b(bank|lender|credit|bond|debt|loan)s?\b.*\b(default|bankrupt|bankruptcy|downgrade|collapse|fail|failure|rescue|bailout|run)\b/i, /\bchapter 11\b/i],
  'company-outlook': [/\b(raises?|cuts?|lowers?|slashes|reaffirms?|withdraws?|boosts?)\b.*\b(guidance|forecast|outlook)\b/i, /\b(downgrades?|upgrades?)\b.*\b(to (buy|sell|hold|neutral|overweight|underweight|outperform|underperform))\b/i],
  results: [/\b(earnings|quarterly|results|profit|revenue|sales|EPS)\b.*\b(beat|beats|miss|misses|tops?|topped|falls? short|rises?|rose|falls?|fell|jumps?|slumps?|surges?|plunges?)\b/i],
  dealmaking: [/\b(to acquire|acquires|acquisition of|agrees to buy|to buy .* for \$|merger|takeover|take-private|buyout|spin-?off|files for (an )?IPO|prices IPO|IPO)\b/i],
  layoffs: [/\b(lay(s)? off|layoffs?|job cuts|cut(s|ting)? [\d,]+ jobs|eliminat(e|es|ing) [\d,]+ (jobs|positions|roles))\b/i],
  funding: [/\braises? \$[\d.]+ ?(million|billion|m|bn|b)\b/i, /\bvaluation of \$[\d.]+ ?(billion|bn|b)\b/i],
  'executive-moves': [/\b(CEO|CFO|COO|chief executive|chief financial officer|chair(man|woman)?)\b.*\b(steps? down|resigns?|ousted|fired|retires?|names?|appoints?|replaced|to step down|departs?)\b/i],
};

// Formats the classifier would reject as features. Without it, stay conservative.
const feature = /^(opinion|analysis|explainer|column|review|commentary|watch|listen|live)\b|\b(opinion|analysis):|\?\s*$|^(how|why|what|where|when|should|is|are|can|could|would|will|do|does)\b|\b(stocks? to (buy|sell|watch)|to buy now|what to know|what we know|things to know|top picks|my portfolio|i bought|i sold|podcast|newsletter|live updates|week ahead|morning brief|evening brief)\b/i;

// Uppercase words that are also tickers; a bare match is too ambiguous, so require $SYM or an exchange tag.
const ambiguous = new Set(['A', 'AI', 'ALL', 'AN', 'ARE', 'AS', 'AT', 'BE', 'BIG', 'CAN', 'CEO', 'DO', 'EU', 'FOR', 'GO', 'HAS', 'IT', 'KEY', 'NEW', 'NOW', 'ON', 'ONE', 'OR', 'OUT', 'SO', 'TV', 'UK', 'UN', 'UP', 'US', 'USA', 'WAY', 'GDP', 'CPI', 'IPO', 'ETF', 'FED', 'SEC', 'DOJ', 'FTC', 'EV', 'AM', 'PM', 'OPEN', 'REAL', 'LOVE', 'FUN', 'CAR', 'HE', 'SHE', 'WE', 'ME', 'MY', 'BY', 'TO', 'OF', 'IN', 'IS', 'NO', 'ANY', 'TECH', 'COST', 'CASH', 'SAFE', 'FAST', 'PLAY', 'TRUE', 'HOME', 'LIFE', 'BEST', 'GOOD', 'NICE', 'MAIN', 'WELL', 'HOOD', 'J', 'X', 'T', 'F', 'C', 'K', 'V', 'O', 'D', 'S', 'U', 'Y', 'Z']);
const nameSuffixes = /\b(incorporated|inc|corporation|corp|company|co|ltd|limited|plc|holdings?|group|class [abc]|common stock|ordinary shares|n\.?v|s\.?a|ag|se|adr|the)\b\.?/gi;
const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function companyName(longName) {
  const core = (longName ?? '').replace(/\(.*?\)/g, ' ').replace(nameSuffixes, ' ').replace(/[,.]/g, ' ').replace(/\s+/g, ' ').trim().replace(/\s*(&|and)$/i, '');
  return core.length >= 4 ? core : '';
}

// Which watched symbols a story names, by cashtag, exchange tag, bare ticker or company name.
export function symbolMentions(item, watched) {
  const text = `${item.title}\n${item.summary?.slice(0, 600) ?? ''}`;
  const hits = [];
  for (const { symbol, name } of watched) {
    const s = escape(symbol);
    const tagged = new RegExp(`\\$${s}\\b|\\((?:NYSE|NASDAQ|Nasdaq|NYSEARCA|AMEX|OTC)[^)]*:\\s*${s}\\)`).test(text);
    const bare = !ambiguous.has(symbol) && symbol.length >= 2 && new RegExp(`(?<![A-Za-z$])${s}(?![A-Za-z])`).test(text);
    const named = name && new RegExp(`\\b${escape(name)}(?:['’]s)?\\b`).test(text);
    if (tagged || bare || named) hits.push(symbol);
  }
  return hits;
}

export function looksLikeFeature(item) {
  return feature.test(item.title.trim());
}

export function trustedPublisher(publisher, trusted) {
  const name = (publisher ?? '').toLowerCase();
  return trusted.some(entry => name === entry.toLowerCase() || name.startsWith(`${entry.toLowerCase()} `));
}

/**
 * Decide one unclassified story without a model. Returns null to leave it for the classifier.
 * `matched` holds topics the story already reached by curated feed or topic search.
 */
export function fallbackVerdict(item, { watched = [], matched = [], trusted = [], now = Date.now(), maxAgeMs = 3 * 3600000 } = {}) {
  if (item.x || !(now - item.stamp <= maxAgeMs) || looksLikeFeature(item)) return null;
  const tickers = symbolMentions(item, watched);
  if (tickers.length) return { reason: 'symbol', topics: matched.map(topic => topic.id), tickers };
  if (matched.length) return { reason: 'curated-source', topics: matched.map(topic => topic.id), tickers: [] };
  if (!trustedPublisher(item.publisher, trusted)) return null;
  const topics = Object.entries(topicRules).filter(([, rules]) => rules.some(rule => rule.test(item.title))).map(([id]) => id);
  return topics.length ? { reason: 'keyword', topics, tickers: [] } : null;
}

/**
 * Pick fallback stories: symbols first, then curated sources, then keyword matches, newest first.
 * A story that may repeat a published or already chosen one is deferred, as it would be without a classifier.
 */
export function selectFallback(entries, published, limit = 6) {
  const order = { symbol: 0, 'curated-source': 1, keyword: 2 };
  const ranked = [...entries].sort((a, b) => order[a.fallback.reason] - order[b.fallback.reason] || b.item.stamp - a.item.stamp);
  const chosen = [];
  const deferred = [];
  for (const entry of ranked) {
    if (chosen.length >= limit) break;
    if (duplicateMatches(entry.item, [...published, ...chosen.map(c => c.item)]).length) deferred.push(entry);
    else chosen.push(entry);
  }
  return { chosen, deferred };
}

const namesFile = join(homedir(), '.config', 'newswire', 'symbol-names.json');

// Held symbols and price-watch symbols from registered devices, with company names cached for a week.
export async function watchedSymbols({ load, lookup = yahooName, file = namesFile, now = Date.now() } = {}) {
  const devices = await load();
  const symbols = [...new Set(devices.flatMap(device => [
    ...JSON.parse(device.stock_symbols ?? '[]'),
    ...JSON.parse(device.price_watches ?? '[]').map(watch => watch.symbol),
  ]).filter(symbol => typeof symbol === 'string' && /^[A-Z][A-Z0-9.-]{0,9}$/.test(symbol)))];
  const cache = JSON.parse(await readFile(file, 'utf8').catch(() => '{}'));
  let changed = false;
  for (const symbol of symbols) {
    if (cache[symbol] && now - Date.parse(cache[symbol].at) < 7 * 86400000) continue;
    // A failed lookup keeps any older name and is retried next run; ticker matching still works meanwhile.
    const name = await lookup(symbol).catch(() => null);
    if (name === null) continue;
    cache[symbol] = { name: companyName(name), at: new Date(now).toISOString() };
    changed = true;
  }
  if (changed) {
    await mkdir(dirname(file), { recursive: true, mode: 0o700 });
    const temporary = `${file}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify(cache)}\n`, { mode: 0o600 });
    await rename(temporary, file);
  }
  return symbols.map(symbol => ({ symbol, name: cache[symbol]?.name ?? '' }));
}

async function yahooName(symbol) {
  const data = await getJson(`https://query1.finance.yahoo.com/v1/finance/search?q=${encodeURIComponent(symbol)}&quotesCount=3&newsCount=0`, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  const quote = (data.quotes ?? []).find(entry => entry.symbol === symbol);
  return quote?.longname ?? quote?.shortname ?? '';
}
