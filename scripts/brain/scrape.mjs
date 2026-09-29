import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { token } from '../monitor/publish.mjs';
import { notify } from '../monitor/apns.mjs';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const stateFile = process.env.BRAIN_SCRAPE_STATE ?? join(homedir(), '.config', 'newswire', 'brain-state.json');
const option = (name, fallback) => process.argv.find(arg => arg.startsWith(`--${name}=`))?.split('=')[1] ?? fallback;
const dryRun = process.argv.includes('--dry-run');
const perRun = Number(option('limit', process.env.BRAIN_PER_RUN ?? 5));
const minScore = Number(option('min-score', process.env.BRAIN_MIN_SCORE ?? 8));
const dailyMax = Number(process.env.BRAIN_DAILY_MAX ?? 24);
const paperPerRun = Number(process.env.BRAIN_PAPERS_PER_RUN ?? 1);
const sourcePerRun = Number(process.env.BRAIN_SOURCE_PER_RUN ?? 2);
const rankModel = process.env.BRAIN_RANK_MODEL ?? '@cf/meta/llama-3.1-8b-instruct-fp8-fast';
const writeModel = process.env.BRAIN_WRITE_MODEL ?? '@cf/meta/llama-3.1-8b-instruct-fp8-fast';
const localAI = process.env.BRAIN_AI_URL?.replace(/\/+$/, '');
const localModel = process.env.BRAIN_AI_LOCAL_MODEL ?? 'gpt-5.6-luna';
const only = option('only', '').split(',').filter(Boolean);
const userAgent = 'newswire-brain/1.0 (personal reader; contact via repository owner)';
const arxivCategories = ['cs.AI', 'cs.LG', 'cs.CL', 'cs.CV'];
const categories = ['AI', 'Tech', 'Security', 'Biotech', 'Science', 'Markets', 'Macro'];

const entities = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
const decode = value => value.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, entity) => {
  if (entity[0] === '#') { const code = entity[1].toLowerCase() === 'x' ? parseInt(entity.slice(2), 16) : Number(entity.slice(1)); return Number.isFinite(code) ? String.fromCodePoint(code) : match; }
  return entities[entity.toLowerCase()] ?? match;
});
const escape = value => String(value).replace(/[&<>"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[char]);
const squash = value => value.replace(/[\u2010\u2011]/g, '-').replace(/[\u202f\u00a0]/g, ' ').replace(/\s+/g, ' ').trim();
const clip = text => text.length > 24000 ? `${text.slice(0, 18000)}\n…\n${text.slice(-6000)}` : text;

export function plain(html) {
  return decode(html
    .replace(/<(script|style|noscript|svg|nav|header|footer|form|button)\b[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<math\b[^>]*?alttext="([^"]*)"[\s\S]*?<\/math>/gi, ' $1 ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|h[1-6]|li|section|tr|figcaption|blockquote)>/gi, '\n')
    .replace(/<[^>]+>/g, ' '))
    .replace(/[ \t\f\v\r]+/g, ' ').replace(/ ?\n[ \n]*/g, '\n\n').trim();
}

export function parseJSON(text) {
  const match = String(text).match(/[[{][\s\S]*[\]}]/);
  if (!match) throw new Error('AI reply had no JSON');
  return JSON.parse(match[0]);
}

async function get(url, { timeout = 20000, as = 'text' } = {}) {
  const response = await fetch(url, { headers: { 'User-Agent': userAgent }, signal: AbortSignal.timeout(timeout) });
  if (!response.ok) throw new Error(`${response.status} ${url}`);
  if (as === 'json') return response.json();
  if (as === 'buffer') return new Uint8Array(await response.arrayBuffer());
  return response.text();
}

async function api(path, body, timeout = 60000) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt) await new Promise(resolve => setTimeout(resolve, 1500 * 2 ** attempt));
    const response = await fetch(new URL(path, origin), {
      method: body ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${await token()}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(timeout),
    }).catch(error => ({ ok: false, status: 0, error }));
    const payload = response.json ? await response.json().catch(() => ({})) : {};
    if (response.ok) return payload;
    lastError = new Error(`${path} ${response.status} ${payload.error?.message ?? response.error?.message ?? ''}`.trim());
    if (response.status && response.status < 500 && response.status !== 429) break;
  }
  throw lastError;
}

async function local(messages, maxTokens) {
  const response = await fetch(`${localAI}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: localModel, messages, max_tokens: maxTokens, temperature: 0.2 }),
    signal: AbortSignal.timeout(180000),
  });
  const payload = await response.json().catch(() => ({}));
  const content = payload.choices?.[0]?.message?.content;
  if (!response.ok || typeof content !== 'string') throw new Error(`local AI ${response.status} ${payload.error?.message ?? ''}`.trim());
  return content;
}

const ai = async (model, system, user, maxTokens) => {
  const messages = [{ role: 'system', content: system }, { role: 'user', content: user }];
  if (localAI) {
    try { return parseJSON(await local(messages, maxTokens)); } catch (error) { console.warn(`brain: ${error.message}; falling back to Workers AI`); }
  }
  return parseJSON((await api('/v1/brain/ai', { model, messages, max_tokens: maxTokens }, 180000)).text);
};

async function arxiv() {
  const query = arxivCategories.map(category => `cat:${category}`).join('+OR+');
  const xml = await get(`https://export.arxiv.org/api/query?search_query=${query}&sortBy=submittedDate&sortOrder=descending&max_results=60`, { timeout: 45000 });
  return [...xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)].map(([, entry]) => {
    const tag = name => squash(decode(entry.match(new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`))?.[1] ?? ''));
    const id = tag('id').replace(/^https?:\/\/arxiv\.org\/abs\//, '').replace(/v\d+$/, '');
    return {
      key: `arxiv:${id}`, kind: 'paper', arxiv: id, title: tag('title'), abstract: tag('summary'), url: `https://arxiv.org/abs/${id}`, source: 'arXiv',
      authors: [...entry.matchAll(/<name>([^<]+)<\/name>/g)].map(match => decode(match[1])), note: entry.match(/primary_category term="([^"]+)"/)?.[1] ?? '', boost: 0,
    };
  }).filter(item => /^\d{4}\.\d{4,5}$/.test(item.arxiv) && item.title);
}

async function huggingFace() {
  const papers = await get('https://huggingface.co/api/daily_papers?limit=30', { as: 'json' });
  return papers.filter(({ paper }) => /^\d{4}\.\d{4,5}$/.test(paper?.id ?? '')).map(({ paper, thumbnail }) => ({
    key: `arxiv:${paper.id}`, kind: 'paper', arxiv: paper.id, title: squash(paper.title), abstract: squash(paper.summary ?? ''), url: `https://arxiv.org/abs/${paper.id}`, source: 'arXiv',
    authors: (paper.authors ?? []).map(author => author.name), image: thumbnail?.startsWith('https://') ? thumbnail : '',
    boost: Math.min(2, (paper.upvotes ?? 0) / 20), note: `${paper.upvotes ?? 0} upvotes on Hugging Face Daily Papers`,
  }));
}

async function hackerNews() {
  const { hits } = await get('https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30', { as: 'json' });
  return hits.filter(hit => hit.title && (hit.points ?? 0) >= 150).map(hit => {
    const discussion = `https://news.ycombinator.com/item?id=${hit.objectID}`;
    const url = hit.url || discussion;
    return { key: `hn:${hit.objectID}`, kind: 'link', title: hit.title, abstract: '', url, source: new URL(url).hostname.replace(/^www\./, ''), discussion, boost: Math.min(1.5, hit.points / 500), note: `${hit.points} points on Hacker News` };
  });
}

async function lobsters() {
  const items = await get('https://lobste.rs/hottest.json', { as: 'json' });
  return items.slice(0, 20).filter(item => item.title && item.url).map(item => ({
    key: `lobsters:${item.short_id ?? item.url}`, kind: 'tech', title: squash(item.title), abstract: squash(item.description ?? ''), url: item.url,
    source: new URL(item.url).hostname.replace(/^www\./, ''), discussion: item.comments_url, boost: Math.min(1.25, Number(item.score ?? 0) / 60), note: `${item.score ?? 0} points on Lobsters`,
  }));
}

async function devCommunity() {
  const items = await get('https://dev.to/api/articles?top=1&per_page=20', { as: 'json' });
  return items.filter(item => item.title && item.url).map(item => ({
    key: `devto:${item.id}`, kind: 'tech', title: squash(item.title), abstract: squash(item.description ?? ''), url: item.url, source: 'dev.to',
    boost: Math.min(1, Number(item.positive_reactions_count ?? 0) / 100), note: `${item.positive_reactions_count ?? 0} reactions on DEV Community`,
  }));
}

const feedValue = (entry, name) => decode(entry.match(new RegExp(`<${name}[^>]*>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?</${name}>`, 'i'))?.[1] ?? '');

export function parseFeed(xml, { key, source, kind = 'news', limit = 20, maxAgeHours = 72 }) {
  const blocks = [...xml.matchAll(/<(item|entry)\b[^>]*>([\s\S]*?)<\/\1>/gi)].map(match => match[2]);
  const cutoff = Date.now() - maxAgeHours * 3600000;
  return blocks.flatMap((entry, index) => {
    const title = squash(plain(feedValue(entry, 'title')));
    const taggedLink = squash(feedValue(entry, 'link'));
    const atomLink = entry.match(/<link\b[^>]*href=["']([^"']+)["']/i)?.[1] ?? '';
    const url = decode(taggedLink || atomLink);
    const description = squash(plain(feedValue(entry, 'description') || feedValue(entry, 'summary') || feedValue(entry, 'content:encoded'))).slice(0, 1200);
    const dateText = feedValue(entry, 'pubDate') || feedValue(entry, 'published') || feedValue(entry, 'updated');
    const published = Date.parse(dateText);
    if (!title || !/^https?:\/\//.test(url) || (Number.isFinite(published) && published < cutoff)) return [];
    return [{ key: `${key}:${url}`, kind, title, abstract: description, url, source, boost: Math.max(0, 0.35 - index * 0.02), note: dateText ? `Published ${dateText}` : `From ${source}` }];
  }).slice(0, limit);
}

async function rss(url, options) {
  return parseFeed(await get(url, { timeout: 30000 }), options);
}

const deepMind = () => rss('https://deepmind.google/blog/rss.xml', { key: 'deepmind', source: 'Google DeepMind', kind: 'tech', limit: 15, maxAgeHours: 168 });
const semafor = () => rss('https://www.semafor.com/rss.xml', { key: 'semafor', source: 'Semafor', limit: 20 });
const yahooFinance = () => rss('https://finance.yahoo.com/news/rssindex', { key: 'yahoo', source: 'Yahoo Finance', kind: 'markets', limit: 20 });

async function polymarket() {
  const markets = await get('https://gamma-api.polymarket.com/markets?active=true&closed=false&limit=30&order=volume24hr&ascending=false', { as: 'json' });
  return markets.filter(market => market.question && Number(market.volume24hr ?? 0) >= 100000).map(market => {
    const outcomes = JSON.parse(market.outcomes ?? '[]');
    const prices = JSON.parse(market.outcomePrices ?? '[]').map(Number);
    const odds = outcomes.map((outcome, index) => `${outcome} ${Math.round((prices[index] ?? 0) * 100)}%`).join(', ');
    const eventSlug = market.events?.[0]?.slug ?? market.slug;
    return {
      key: `polymarket:${market.id}`, kind: 'markets', title: squash(market.question), abstract: `Current market odds: ${odds}. 24-hour volume: $${Math.round(Number(market.volume24hr)).toLocaleString('en-US')}.`,
      url: `https://polymarket.com/event/${eventSlug}`, source: 'Polymarket', boost: Math.min(1.25, Number(market.volume24hr) / 1000000), note: 'Active prediction market',
    };
  });
}

const sources = { hn: hackerNews, lobsters, devto: devCommunity, deepmind: deepMind, semafor, yahoo: yahooFinance, polymarket, arxiv, huggingface: huggingFace };

async function collect() {
  const merged = new Map();
  const failures = [];
  for (const [name, load] of Object.entries(sources)) {
    if (only.length && !only.includes(name)) continue;
    try {
      for (const item of await load()) merged.set(item.key, { ...merged.get(item.key), ...item, boost: Math.max(item.boost, merged.get(item.key)?.boost ?? 0) });
    } catch (error) { failures.push(`${name}: ${error.message}`); }
  }
  return { items: [...merged.values()], failures };
}

function tasteText(taste) {
  const line = signal => `- [${signal.category}] ${squash(signal.title || signal.content).slice(0, 200)}`;
  const liked = taste.signals.filter(signal => signal.type !== 'dislike').slice(0, 50).map(line);
  const disliked = taste.signals.filter(signal => signal.type === 'dislike').slice(0, 20).map(line);
  return `Liked or saved:\n${liked.join('\n') || '- (none yet)'}\n\nDisliked:\n${disliked.join('\n') || '- (none yet)'}\n\nAlready in the feed recently (repeats score low):\n${taste.recent.slice(0, 60).map(title => `- ${squash(title).slice(0, 140)}`).join('\n')}`;
}

const rankPrompt = `You choose stories for Bryce's personal reading feed. Score each candidate 1-10 for how much he would want to read it, judged against his taste signals. Be strict: in a typical batch of 30 only one to three items deserve 8 or more, and most papers score 3-6.
9-10: squarely on his strongest interests and a notable development people will talk about.
8: clearly relevant with a concrete, surprising, or practically useful result.
5-7: relevant but incremental, narrow, or routine.
1-4: off-topic, generic, a repeat of something already in the feed, or like his disliked items.
Papers need a concrete notable result, new capability, surprising finding, or practical tool; incremental benchmark gains, narrow domain applications, and surveys score low.
Prefer fresh reporting, major product/model releases, useful tools, market-moving developments, security incidents, and strong analysis over academic papers. Prediction markets are signals, not facts; only score them highly when the topic and volume are meaningful.
Choose category from: ${categories.join(', ')}.
Reply with only a JSON array like [{"i":0,"score":7,"category":"AI"}] covering every candidate.`;

async function rank(items, taste) {
  const profile = tasteText(taste);
  const scored = [];
  for (let start = 0; start < items.length; start += 30) {
    const batch = items.slice(start, start + 30);
    const list = batch.map((item, i) => `${i}. ${item.title}${item.abstract ? ` — ${item.abstract.slice(0, 320)}` : ''} (${item.note || item.source})`).join('\n');
    const verdicts = await ai(rankModel, rankPrompt, `${profile}\n\nCandidates:\n${list}`, 4000);
    for (const verdict of Array.isArray(verdicts) ? verdicts : []) {
      const item = batch[verdict?.i];
      const score = Number(verdict?.score);
      if (!item || !Number.isFinite(score)) continue;
      scored.push({ ...item, score: Math.max(1, Math.min(10, score)), category: categories.includes(verdict.category) ? verdict.category : 'AI' });
    }
  }
  return scored;
}

async function paperText(id) {
  try {
    const html = await get(`https://arxiv.org/html/${id}`, { timeout: 45000 });
    const article = (html.match(/<article[\s\S]*<\/article>/i)?.[0] ?? html).replace(/<section[^>]*ltx_bibliography[\s\S]*$/i, '');
    const text = plain(article);
    if (text.length > 3000) return { text: clip(text), from: 'HTML' };
  } catch { }
  try {
    const { extractText, getDocumentProxy } = await import('unpdf');
    const pdf = await getDocumentProxy(await get(`https://arxiv.org/pdf/${id}`, { as: 'buffer', timeout: 90000 }));
    const { text } = await extractText(pdf, { mergePages: true });
    const body = String(text).split(/\n\s*(?:References|Bibliography)\s*\n/i)[0];
    if (body.length > 3000) return { text: clip(body), from: 'PDF' };
  } catch { }
  return null;
}

async function linkText(url) {
  if (/\.pdf($|\?)/i.test(url)) return null;
  try {
    const html = await get(url, { timeout: 20000 });
    const main = html.match(/<article[\s\S]*<\/article>/i)?.[0] ?? html.match(/<main[\s\S]*<\/main>/i)?.[0] ?? html.match(/<body[\s\S]*<\/body>/i)?.[0] ?? html;
    const text = plain(main);
    return text.length > 600 ? { text: text.slice(0, 20000), from: 'page' } : null;
  } catch { return null; }
}

const writePrompt = `You write for Bryce's personal news reader. From the source below, reply with only JSON:
{"title": "...", "takeaway": "...", "summary": "...", "points": ["..."], "why": "..."}
title: sentence-case headline in plain English, at most 80 characters, that a smart non-specialist understands and that says what was found or what happened. Include one concrete detail where possible. No jargon, parameter counts, metric names, symbols, or paper-style colon subtitles; no clickbait.
takeaway: one plain-English sentence, at most 200 characters, leading with the insight like a knowledgeable friend, with the single most telling number if there is one.
summary: 2-3 plain-English sentences, at most 450 characters: what they did, what they found, and the main caveat.
points: 3-5 short bullets with the concrete findings, numbers, methods, or caveats stated in the source; technical terms are fine here if briefly explained.
why: one sentence on why it matters, or an empty string.
Use only facts in the source. Never invent numbers or claims.`;

async function write(item) {
  const text = item.kind === 'paper' ? await paperText(item.arxiv) : await linkText(item.url);
  const context = [`Original title: ${item.title}`, item.authors?.length ? `Authors: ${item.authors.slice(0, 8).join(', ')}` : '', item.abstract ? `Abstract: ${item.abstract}` : '', text ? `\nFull text (${text.from}):\n${text.text}` : ''].filter(Boolean).join('\n');
  if (!text && !item.abstract) return null;
  const draft = await ai(writeModel, writePrompt, context, 3000);
  const title = squash(String(draft.title ?? '')).slice(0, 120);
  const takeaway = squash(String(draft.takeaway ?? ''));
  const summary = squash(String(draft.summary ?? ''));
  const points = (Array.isArray(draft.points) ? draft.points : []).map(point => squash(String(point))).filter(Boolean).slice(0, 6);
  if (!title || !summary) throw new Error('AI draft missing title or summary');
  const credit = item.kind === 'paper'
    ? `Original title: ${item.title}. ${item.authors?.length ? `${item.authors.slice(0, 4).join(', ')}${item.authors.length > 4 ? ' et al' : ''}. ` : ''}Summarized from the arXiv ${text?.from ?? 'abstract'}${item.note?.includes('upvotes') ? `; ${item.note}` : ''}.`
    : [`Original title: ${item.title}.`, item.note, item.discussion ? `Discussion: ${item.discussion}` : ''].filter(Boolean).join(' ');
  const body = [`<p>${escape(summary)}</p>`, points.length ? `<h3>Key points</h3><ul>${points.map(point => `<li>${escape(point)}</li>`).join('')}</ul>` : '',
    draft.why ? `<p><strong>Why it matters:</strong> ${escape(squash(String(draft.why)))}</p>` : '', `<p><em>${escape(credit)}</em></p>`].join('');
  return {
    content: `${title}. ${takeaway || summary}`.slice(0, 600), title, summary: summary.slice(0, 2000), body, source: item.source, source_url: item.url,
    source_type: item.kind === 'paper' ? 'paper' : item.kind === 'tech' ? 'tech' : 'news', category: item.category, priority: Math.round(Math.max(1, Math.min(10, item.score))), ...(item.image ? { image_url: item.image } : {}),
  };
}

export function chooseBalanced(items, limit, { maxPapers = 1, maxPerSource = 2 } = {}) {
  const chosen = [];
  const sourceCounts = new Map();
  let papers = 0;
  const words = title => new Set(String(title).toLowerCase().match(/[a-z0-9]{4,}/g)?.filter(word => !['after', 'before', 'about', 'their', 'there', 'these', 'those', 'with', 'from', 'into', 'will', 'could', 'would'].includes(word)) ?? []);
  const repeatsStory = item => {
    const candidate = words(item.title);
    return chosen.some(existing => {
      const prior = words(existing.title);
      let overlap = 0;
      for (const word of candidate) if (prior.has(word)) overlap += 1;
      return overlap >= 3;
    });
  };
  for (const item of items) {
    if (chosen.length >= limit) break;
    if (item.kind === 'paper' && papers >= maxPapers) continue;
    const source = item.source ?? 'unknown';
    if ((sourceCounts.get(source) ?? 0) >= maxPerSource) continue;
    if (repeatsStory(item)) continue;
    chosen.push(item);
    sourceCounts.set(source, (sourceCounts.get(source) ?? 0) + 1);
    if (item.kind === 'paper') papers += 1;
  }
  return chosen;
}

export function capForRanking(items, maxPerSource = 12, maxPapers = 24) {
  const counts = new Map();
  let papers = 0;
  return items.filter(item => {
    if (item.kind === 'paper') {
      if (papers >= maxPapers) return false;
      papers += 1;
      return true;
    }
    const source = item.source ?? 'unknown';
    if ((counts.get(source) ?? 0) >= maxPerSource) return false;
    counts.set(source, (counts.get(source) ?? 0) + 1);
    return true;
  });
}

async function loadState() {
  try { const state = JSON.parse(await readFile(stateFile, 'utf8')); return { seen: state.seen ?? {}, pending: state.pending ?? [], written: state.written ?? [] }; } catch { return { seen: {}, pending: [], written: [] }; }
}

async function saveState(state) {
  const now = Date.now();
  const seen = Object.fromEntries(Object.entries(state.seen).filter(([, at]) => now - Date.parse(at) < 14 * 86400000));
  const pending = state.pending.filter(item => now - Date.parse(item.at) < 72 * 3600000 && (item.attempts ?? 0) < 3).slice(0, 40);
  const written = state.written.filter(at => now - Date.parse(at) < 86400000);
  await mkdir(dirname(stateFile), { recursive: true, mode: 0o700 });
  const temporary = `${stateFile}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify({ seen, pending, written }, null, 1)}\n`, { mode: 0o600 });
  await rename(temporary, stateFile);
}

async function main() {
  const state = await loadState();
  const { items, failures } = await collect();
  const fresh = items.filter(item => !state.seen[item.key] && !state.pending.some(pending => pending.key === item.key));
  const known = new Set();
  for (let start = 0; start < fresh.length; start += 200) (await api('/v1/brain/known', { urls: fresh.slice(start, start + 200).map(item => item.url) })).known.forEach(url => known.add(url));
  const candidates = capForRanking(fresh.filter(item => !known.has(item.url)));
  const now = new Date().toISOString();
  const ranked = candidates.length ? await rank(candidates, await api('/v1/brain/taste')) : [];
  for (const item of candidates) state.seen[item.key] = now;
  const keep = ranked.filter(item => item.score >= (item.kind === 'paper' ? Math.max(9, minScore) : minScore)).map(item => ({ ...item, final: item.score + item.boost, at: now, attempts: 0 }));
  state.pending = [...state.pending, ...keep].sort((a, b) => b.final - a.final);
  const posts = [];
  const budget = Math.max(0, dailyMax - state.written.filter(at => Date.now() - Date.parse(at) < 86400000).length);
  const chosen = chooseBalanced(state.pending, Math.min(perRun, budget), { maxPapers: paperPerRun, maxPerSource: sourcePerRun });
  for (const item of chosen) {
    try {
      const post = await write(item);
      if (post) { posts.push(post); state.written.push(now); }
      state.pending = state.pending.filter(pending => pending.key !== item.key);
    } catch (error) {
      item.attempts = (item.attempts ?? 0) + 1;
      failures.push(`write ${item.key}: ${error.message}`);
    }
  }
  let result = { inserted: 0, duplicates: 0 };
  if (dryRun) for (const post of posts) console.log(JSON.stringify({ title: post.title, priority: post.priority, category: post.category, url: post.source_url, content: post.content }, null, 1));
  else {
    const routine = posts.filter(post => post.priority < 8);
    if (routine.length) result = await api('/v1/brain/posts', { posts: routine });
    const alerts = [];
    for (const post of posts.filter(post => post.priority >= 8)) {
      const single = await api('/v1/brain/posts', { posts: [post] });
      result = { inserted: result.inserted + single.inserted, duplicates: result.duplicates + single.duplicates };
      if (single.inserted) alerts.push({ title: post.title, source: post.source || 'Brain', url: post.source_url, priority: post.priority >= 10 ? 'breaking' : 'urgent', feed: 'brain' });
    }
    failures.push(...await notify(alerts).catch(error => [`notify: ${error.message}`]));
    await saveState(state);
  }
  const mix = posts.reduce((counts, post) => ({ ...counts, [post.source]: (counts[post.source] ?? 0) + 1 }), {});
  console.log(`brain: ${items.length} fetched, ${candidates.length} new, ${ranked.length} ranked, ${keep.length} kept, ${posts.length} written, ${result.inserted} inserted, ${state.pending.length} queued, mix ${JSON.stringify(mix)}${dryRun ? ' (dry run)' : ''}`);
  for (const failure of failures) console.error(`failure: ${failure}`);
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch(error => {
  if (/daily free allocation|used up.*neurons/i.test(error.message)) {
    console.log('brain: AI quota exhausted; deferred until the next scheduled run');
    return;
  }
  console.error(`brain scraper failed: ${error.message}`);
  process.exitCode = 1;
});
