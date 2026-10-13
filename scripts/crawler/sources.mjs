import { createHash } from 'node:crypto';

export function canonicalUrl(value) {
  try {
    const url = new URL(requestUrl(value));
    url.hostname = url.hostname.toLowerCase().replace(/^www\./, '');
    url.protocol = 'https:';
    return url.href;
  } catch { return null; }
}

export function requestUrl(value) {
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
    url.hash = '';
    for (const key of [...url.searchParams.keys()]) if (/^(utm_|fbclid|gclid|mc_[ce]id|ref$)/i.test(key)) url.searchParams.delete(key);
    url.searchParams.sort();
    if (url.pathname.length > 1) url.pathname = url.pathname.replace(/\/+$/, '');
    return url.href;
  } catch { return null; }
}

export function stableId(value) { return createHash('sha256').update(String(value)).digest('hex'); }

export function parseFeed(xml, feed = {}) {
  const blocks = [...xml.matchAll(/<(item|entry)\b[^>]*>([\s\S]*?)<\/\1>/gi)].map(m => m[2]);
  const text = (block, names) => {
    for (const name of names) {
      const escaped = name.replace(':', '\\:');
      const match = new RegExp(`<${escaped}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${escaped}>`, 'i').exec(block);
      if (match) return decode(match[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').replace(/<[^>]+>/g, ' ').trim());
    }
    return '';
  };
  return blocks.map(block => {
    const atom = /<link\b[^>]*href=["']([^"']+)["']/i.exec(block)?.[1];
    const url = requestUrl(text(block, ['link']) || atom || text(block, ['id']));
    const title = text(block, ['title']);
    if (!url || !title) return null;
    const published = text(block, ['pubDate', 'published', 'updated', 'dc:date']);
    const summary = text(block, ['description', 'summary', 'content:encoded']).slice(0, 12000);
    return { url, title, summary, published_at: Number.isFinite(Date.parse(published)) ? new Date(published).toISOString() : null,
      publisher: text(block, ['source']) || feed.name || new URL(url).hostname, guid: text(block, ['guid', 'id']) || url,
      via: feed.name ?? 'RSS', topics: feed.topics ?? [] };
  }).filter(Boolean);
}

export function extractLinks(html, baseUrl, limit = 12) {
  const out = [], seen = new Set();
  for (const match of html.matchAll(/<a\b([^>]*?)href\s*=\s*(["'])(.*?)\2([^>]*)>([\s\S]*?)<\/a\s*>/gi)) {
    const attrs = `${match[1]} ${match[4]}`;
    const rel = /\brel\s*=\s*(["'])(.*?)\1/i.exec(attrs)?.[2] ?? '';
    if (/nofollow|ugc|sponsored/i.test(rel)) continue;
    const href = match[3].replace(/&amp;/g, '&').trim();
    let url;
    try { url = requestUrl(new URL(href, baseUrl).href); } catch { continue; }
    const title = decode(match[5].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim());
    if (!url || seen.has(url) || !title || title.length < 18 || /javascript:|mailto:|\.pdf(?:[?#]|$)/i.test(href)) continue;
    if (/\b(?:login|sign[ -]?in|subscribe|newsletter|privacy|terms|contact|search|account)\b/i.test(title)) continue;
    seen.add(url);
    out.push({ url, title: title.slice(0, 500) });
    if (out.length >= limit) break;
  }
  return out;
}

export function articleText(html) {
  const withoutNoise = html.replace(/<(script|style|nav|header|footer|aside|form)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ');
  const title = metaValue(html, ['og:title'])
    ?? /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1]
    ?? /<h1\b[^>]*>([\s\S]*?)<\/h1>/i.exec(html)?.[1] ?? '';
  const description = metaValue(html, ['og:description', 'description']) ?? '';
  const published = metaValue(html, ['article:published_time', 'datePublished', 'date', 'pubdate'])
    ?? /<time\b[^>]*datetime=["']([^"']+)/i.exec(html)?.[1]
    ?? /["']datePublished["']\s*:\s*["']([^"']+)/i.exec(html)?.[1] ?? '';
  const publishedMs = Date.parse(decode(published));
  const article = /<(?:article|main)\b[^>]*>([\s\S]*?)<\/(?:article|main)>/i.exec(withoutNoise)?.[1] ?? withoutNoise;
  const body = decode(article.replace(/<(script|style|svg|noscript)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()).slice(0, 30000);
  return { title: decode(title.replace(/<[^>]+>/g, ' ').trim()), summary: decode(description).slice(0, 3000), body,
    published_at: Number.isFinite(publishedMs) ? new Date(publishedMs).toISOString() : null };
}

function metaValue(html, names) {
  const wanted = new Set(names.map(name => name.toLowerCase()));
  for (const tag of html.matchAll(/<meta\b[^>]*>/gi)) {
    const attrs = Object.fromEntries([...tag[0].matchAll(/([\w:-]+)\s*=\s*(["'])(.*?)\2/g)].map(match => [match[1].toLowerCase(), match[3]]));
    if (wanted.has((attrs.property ?? attrs.name ?? '').toLowerCase()) && attrs.content) return attrs.content;
  }
  return null;
}

export function buildSearchQuestions(seed, now = Date.now(), exploreFraction = 0.3) {
  const subject = conciseSubject(seed.title ?? seed.query ?? '');
  if (!subject) return [];
  const id = stableId(seed.event_id ?? seed.url ?? subject).slice(0, 20);
  const qs = [
    ['confirm', `${subject} official confirmation corroboration`],
    ['contradict', `${subject} denial correction reversal disputes`],
  ];
  if (exploreFraction > 0) qs.push(['explore', `${subject} market impact causes related developments`]);
  return qs.map(([search_role, query]) => ({ id: stableId(`${id}\n${search_role}`).slice(0, 24), query, reason: `${search_role} search for ${subject}`,
    status: 'open', created_at: new Date(now).toISOString(), event_id: seed.event_id ?? id, search_role, budget_group: id }));
}

function conciseSubject(value) {
  const clean = String(value).replace(/\s+/g, ' ').replace(/["“”‘’]/g, '').trim();
  const words = clean.match(/[A-Za-z0-9$%.-]+/g) ?? [];
  const stop = new Set(['the','a','an','and','or','of','to','in','on','for','as','by','with','after','before','from','says','said','report','reports','reported','update','latest','live','what','how','why','will','could','may','market','markets','news']);
  const useful = words.filter(word => !stop.has(word.toLowerCase()));
  const entities = useful.filter(word => /^[A-Z0-9$][A-Z0-9$.-]*$/.test(word));
  const selected = entities.length >= 2 ? [...entities, ...useful.filter(word => !entities.includes(word)).slice(0, 4)] : useful;
  return (selected.slice(0, 8).join(' ') || clean.split(' ').slice(0, 8).join(' ')).slice(0, 120);
}

export function searchUrls(query, discovery = {}) {
  const urls = [];
  if (discovery.googleNews !== false) urls.push(`https://news.google.com/rss/search?q=${encodeURIComponent(query)}&hl=en-US&gl=US&ceid=US:en`);
  if (discovery.gdelt !== false) urls.push(`https://api.gdeltproject.org/api/v2/doc/doc?query=${encodeURIComponent(query)}&mode=ArtList&format=rss&maxrecords=15&sort=DateDesc`);
  return urls;
}

function decode(value) {
  return value.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(Number.parseInt(n, 16)))
    .replace(/&quot;/g, '"').replace(/&apos;|&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
}
