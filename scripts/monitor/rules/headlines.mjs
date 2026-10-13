import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { getText } from '../fetch.mjs';
import { ask, classifierIdentity } from '../jev.mjs';
import { recent } from '../publish.mjs';
import { load } from '../state.mjs';
import { timeline } from '../x.mjs';
import { readableCopy, walled } from '../syndication.mjs';
import { archiveHeadlines } from '../headline-archive.mjs';
import { canonicalUrl, dedupeCandidates, exactDuplicate, nearIdentical, recordDedupe } from '../headline-dedupe.mjs';

export const id = 'headlines';

const config = JSON.parse(readFileSync(new URL('./headlines.watchlist.json', import.meta.url), 'utf8'));
const rank = { breaking: 0, urgent: 1, normal: 2 };
const topics = config.topics;
const classified = topics.filter(topic => topic.description);
const offTopic = 'off-topic';
const criteria = {
  ...Object.fromEntries(classified.map(topic => [topic.id, topic.description])),
  [offTopic]: 'None of the topics above, or only a passing mention: unrelated opinion, lifestyle, sports, entertainment, crime, weather, and general news are off-topic. Evidence-based financial analysis can match market-analysis.',
};
const verdictsFile = join(homedir(), '.config', 'newswire', 'headlines-verdicts.json');
export const topicQuestion = {
  topic: {
    criteria,
    instructions: 'Classify this news story by the single watchlist topic it is primarily and directly about. Choose off-topic unless the story squarely reports on one topic.',
  },
};
export const detailQuestions = {
  format: {
    criteria: {
      news: 'Reports a specific new event or decision that just happened or was just announced: a deal, a ruling, a filing, a result, an appointment, a policy change, official figures, a company action.',
      feature: 'Analysis, opinion, commentary, column, explainer, how-it-works, profile, first-person essay, advice, weekly roundup, scene-setting or campaign-trail color, speculation about what might happen, or a human-interest story about one person.',
    },
    instructions: 'Is this story hard news about a specific new event, or a feature? Anything that mainly explains, argues, profiles, or reflects is a feature.',
  },
  priority: {
    criteria: {
      breaking: 'Major, fast-moving news most people would want an immediate phone alert for: war or major attack, head of state news, market crash, huge disaster, landmark ruling, or an event that moves markets right now.',
      urgent: 'Significant, time-sensitive news worth reading today, but not worth interrupting someone for.',
      normal: 'Routine coverage, analysis, features, or incremental updates.',
    },
    instructions: 'How urgent is this news story? Reserve breaking for rare, major events.',
  },
  significance: {
    criteria: {
      'systemic-event': 'A concrete development with broad consequences: military escalation or de-escalation, a credible new official war threat or deployment, shipping or energy supply disruption, major economic data or monetary/trade policy, or systemic banking stress. Not an incidental mention of war, tariffs or inflation in a stock opinion.',
      'material-company-event': 'A material company development: earnings, guidance changes, major deals, defaults, dividend cuts or suspensions, or a substantial dividend change. Not an unchanged routine dividend declaration.',
      'routine-company-update': 'A routine dividend declaration or ex-dividend reminder, stock picks, or generic what-next / should-you-buy stock commentary with no material new development.',
      other: 'Other reporting or analysis; insufficient evidence for any of the above.',
    },
    instructions: 'Classify the substantive new development, separately from alert urgency. Judge only the supplied evidence. Routine stock coverage is not broadly important just because it mentions a major macro event.',
  },
};

export function significanceTag(answers, minimum = config.min_confidence ?? 0.7) {
  const answer = answers.significance;
  return answer?.confidence >= minimum && answer.choice !== 'other' && Object.hasOwn(detailQuestions.significance.criteria, answer.choice) ? answer.choice : null;
}
const classificationVersion = createHash('sha256').update(JSON.stringify({ topics, topicQuestion, detailQuestions, classifierIdentity })).digest('hex').slice(0, 12);
const formats = new Set(config.skip_sections ?? ['video', 'videos', 'live', 'live-updates', 'live-news', 'opinion', 'opinions', 'briefing', 'podcast', 'podcasts', 'newsletters', 'gallery', 'pictures', 'interactive']);
// Quote, option-chain and calendar pages surface through Google News with article-style links.
const quotePage = /stock price, news, quote & history$|interactive stock chart|^earnings calendar for\b|^-\s*yahoo|^meta_title_/i;

// Formats Jev always rejects, decided from the URL alone: clips, live blogs, opinion, briefings, galleries.
// X posts mostly in another script are local promos, never US news.
export function prefiltered(item) {
  if (quotePage.test(item.title)) return true;
  let segments = [];
  try { segments = new URL(item.url).pathname.toLowerCase().split('/'); } catch { return false; }
  if (!item.x && segments.some(segment => formats.has(segment))) return true;
  if (item.x) {
    const letters = item.title.match(/\p{L}/gu) ?? [];
    return letters.length > 0 && letters.filter(letter => /[a-z]/i.test(letter)).length / letters.length < 0.5;
  }
  return false;
}

function decode(text) {
  return text
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(Number.parseInt(code, 16)))
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

function field(xml, name) {
  const match = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${name}>`).exec(xml);
  if (!match) return '';
  return match[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').trim();
}

function link(xml) {
  const simple = field(xml, 'link');
  if (/^https?:\/\//.test(simple)) return simple;
  return /<link[^>]*href="(https?:[^"]+)"/.exec(xml)?.[1] ?? '';
}

function image(xml) {
  const candidates = [
    /<media:content[^>]*url="([^"]+)"[^>]*>/.exec(xml)?.[1],
    /<media:thumbnail[^>]*url="([^"]+)"/.exec(xml)?.[1],
    /<enclosure[^>]*type="image[^"]*"[^>]*url="([^"]+)"/.exec(xml)?.[1] ?? /<enclosure[^>]*url="([^"]+\.(?:jpe?g|png|webp)[^"]*)"/i.exec(xml)?.[1],
    /<img[^>]*src=(?:"|&quot;)(https:[^"&]+(?:&amp;[^"&]+)*)/.exec(xml)?.[1],
  ];
  const found = candidates.find(candidate => candidate && /^https:\/\//.test(decode(candidate)));
  return found ? decode(found) : '';
}

function stripTags(text) {
  return text.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

function slug(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'feed';
}

export function parseFeed(xml, feedName) {
  const blocks = [...(xml.match(/<item[\s\S]*?<\/item>/g) ?? []), ...(xml.match(/<entry[\s\S]*?<\/entry>/g) ?? [])];
  const items = [];
  for (const block of blocks) {
    const publisher = field(block, 'source') || feedName;
    let title = decode(field(block, 'title')).replace(/\s+/g, ' ').trim();
    if (publisher && title.endsWith(` - ${publisher}`)) title = title.slice(0, -publisher.length - 3).trim();
    let url = decode(link(block));
    try {
      const parsed = new URL(url);
      parsed.searchParams.delete('.tsrc');
      url = parsed.href;
    } catch { continue; }
    const guid = field(block, 'guid') || field(block, 'id') || url;
    const date = field(block, 'pubDate') || field(block, 'published') || field(block, 'updated') || field(block, 'dc:date');
    const stamp = Math.min(Date.parse(/^\d{4}-\d{2}-\d{2}[ T][\d:.]+$/.test(date) ? `${date.replace(' ', 'T')}Z` : date), Date.now());
    const summary = distinctSummary(decode(stripTags(field(block, 'description') || field(block, 'summary') || field(block, 'content:encoded'))), title, publisher);
    if (!title || !/^https?:\/\//.test(url) || !guid || !Number.isFinite(stamp)) continue;
    items.push({ title, url, guid, stamp, summary, publisher, image: image(block) });
  }
  return items;
}

function comparable(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function distinctSummary(summary, title, publisher) {
  let rest = comparable(summary);
  const heading = comparable(title);
  if (rest.startsWith(heading)) rest = rest.slice(heading.length).trim();
  if (publisher && rest.endsWith(comparable(publisher))) rest = rest.slice(0, -comparable(publisher).length).trim();
  if (rest.length < 25 || heading.includes(rest)) return '';
  return summary;
}

function googleNewsUrl(query) {
  return `https://news.google.com/rss/search?q=${encodeURIComponent(query)}&hl=en-US&gl=US&ceid=US:en`;
}

export async function resolveGoogleNews(url) {
  const id = /^https:\/\/news\.google\.com\/(?:rss\/)?articles\/([^?/]+)/.exec(url)?.[1];
  if (!id) return url;
  try {
    const page = await getText(`https://news.google.com/rss/articles/${id}`);
    const signature = /data-n-a-sg="([^"]+)"/.exec(page)?.[1];
    const timestamp = /data-n-a-ts="([^"]+)"/.exec(page)?.[1];
    if (!signature || !timestamp) throw new Error('no signature');
    const request = [[['Fbv4je', `["garturlreq",[["X","X",["X","X"],null,null,1,1,"US:en",null,1,null,null,null,null,null,0,1],"X","X",1,[1,1,1],1,1,null,0,0,null,0],"${id}",${timestamp},"${signature}"]`, null, 'generic']]];
    const response = await fetch('https://news.google.com/_/DotsSplashUi/data/batchexecute', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: `f.req=${encodeURIComponent(JSON.stringify(request))}`,
      signal: AbortSignal.timeout(15000),
    });
    const resolved = JSON.parse(JSON.parse((await response.text()).split('\n\n')[1])[0][2])[1];
    if (/^https?:\/\//.test(resolved)) return resolved;
    throw new Error('no url');
  } catch {
    return `https://news.google.com/articles/${id}`;
  }
}

export function balanceHeadlines(events, maxX = config.max_x_per_run ?? 2) {
  let xCount = 0;
  return [...events].sort((a, b) => rank[a.priority] - rank[b.priority] || Number(a.tags.includes('x')) - Number(b.tags.includes('x')) || Date.parse(b.published_at) - Date.parse(a.published_at))
    .filter(event => !event.tags.includes('x') || xCount++ < maxX);
}

export function acceptedTopic(answers, { x = false, minimum = config.min_confidence ?? 0.7 } = {}) {
  const topic = classified.find(candidate => candidate.id === answers.topic?.choice);
  if (!topic || answers.topic.confidence < minimum || !answers.format || answers.format.confidence < minimum) return null;
  return answers.format.choice === 'news' || (!x && topic.allow_analysis && answers.format.choice === 'feature') ? topic.id : null;
}

export async function run({ lookbackHours } = {}) {
  if (lookbackHours !== undefined && (!Number.isFinite(lookbackHours) || lookbackHours < 1 || lookbackHours > 168)) throw new Error('lookbackHours must be 1–168');
  const events = [];
  const failures = [];
  const windowMs = lookbackHours === undefined ? (config.window_minutes ?? 30) * 60000 : lookbackHours * 3600000;
  const seen = new Map();

  const sources = [
    ...config.feeds.map(feed => ({ ...feed, via: feed.via ?? [] })),
    ...topics.filter(topic => topic.query).map(topic => ({ name: `Google News: ${topic.label}`, url: googleNewsUrl(topic.query), via: [topic.id] })),
  ];

  const settled = await Promise.allSettled(sources.map(async source => {
    const xml = await getText(source.url);
    if (!/<(?:rss|feed)\b/i.test(xml)) throw new Error('Expected an RSS or Atom feed');
    return parseFeed(xml, source.name).map(item => ({ ...item, via: source.via, windowMs: lookbackHours === undefined ? (source.window_minutes ?? config.window_minutes ?? 30) * 60000 : windowMs }));
  }));
  if (config.x !== false) {
    sources.push({ name: 'X Following' });
    settled.push(...await Promise.allSettled([timeline().then(posts => posts.map(item => ({ ...item, via: [] })))]));
  }

  const intake = settled.filter(entry => entry.status === 'fulfilled').flatMap(entry => entry.value).filter(item => !prefiltered(item));
  const archived = await archiveHeadlines(intake);
  if (archived.truncated) failures.push('headlines raw archive reached 10000-story cap');
  if (lookbackHours !== undefined) {
    sources.push({ name: 'Local raw headline archive' });
    settled.push({ status: 'fulfilled', value: archived.records.map(item => ({ ...item, windowMs })) });
  }

  settled.forEach((entry, index) => {
    if (entry.status === 'rejected') {
      failures.push(`${sources[index].name}: ${entry.reason?.message ?? entry.reason}`);
      return;
    }
    for (const item of entry.value) {
      if (Date.now() - item.stamp > (item.windowMs ?? windowMs) || prefiltered(item)) continue;
      const key = `headlines:${slug(item.publisher)}:${createHash('sha256').update(item.guid).digest('hex').slice(0, 24)}`;
      const matched = topics.filter(topic => item.via.includes(topic.id));
      if (!seen.has(key)) seen.set(key, { key, item, matched: [] });
      for (const topic of matched) if (!seen.get(key).matched.includes(topic)) seen.get(key).matched.push(topic);
    }
  });

  const state = await load();
  const verdicts = Object.fromEntries(Object.entries(JSON.parse(await readFile(verdictsFile, 'utf8').catch(() => '{}'))).filter(([, verdict]) => verdict.version === classificationVersion));
  const minimum = config.min_confidence ?? 0.7;
  let published = [];
  let historyAvailable = true;
  try {
    published = await recent(config.dedupe_hours ?? 24);
  } catch (error) {
    historyAvailable = false;
    failures.push(`headlines dedupe: ${error.message}`);
  }
  // Exact and near-identical copies skip classification entirely, saving free-tier quota.
  const urls = new Set(published.map(story => canonicalUrl(story.url)).filter(Boolean));
  const firstCopies = [];
  for (const entry of seen.values()) {
    if (state[entry.key]) continue;
    const link = canonicalUrl(entry.item.url);
    if ((link && urls.has(link)) || [...published, ...firstCopies].some(story => exactDuplicate(entry.item, story) || nearIdentical(entry.item, story))) entry.duplicate = true;
    else firstCopies.push(entry.item);
    if (link) urls.add(link);
  }
  const apply = (entry, verdict) => {
    const topic = classified.find(candidate => candidate.id === verdict.topic);
    if (!entry.matched.length && topic) entry.matched.push(topic);
    entry.priority = verdict.priority;
    entry.significance = verdict.significance;
    if (verdict.duplicate) entry.duplicate = true;
  };
  for (const entry of seen.values()) if (verdicts[entry.key]) apply(entry, verdicts[entry.key]);
  const pending = [...seen.values()].filter(entry => !state[entry.key] && !verdicts[entry.key] && !entry.duplicate);
  const cacheWindowMs = Math.max(windowMs, ...config.feeds.map(feed => (feed.window_minutes ?? config.window_minutes ?? 30) * 60000));
  const checkpoint = async () => {
    const kept = Object.fromEntries(Object.entries(verdicts).filter(([, verdict]) => Date.now() - Date.parse(verdict.at) < 2 * cacheWindowMs));
    await mkdir(dirname(verdictsFile), { recursive: true, mode: 0o700 });
    const temporary = `${verdictsFile}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify(kept)}\n`, { mode: 0o600 });
    await rename(temporary, verdictsFile);
  };
  let classifyError;
  for (let start = 0; start < Math.min(pending.length, 16) && !classifyError; start += 8) {
    await Promise.all(pending.slice(start, start + 8).map(async entry => {
      try {
        const text = `${entry.item.title}\n\n${entry.item.summary.slice(0, 300)}`.trim();
        const { topic } = await ask(text, topicQuestion);
        const onTopic = topic.confidence >= minimum && topic.choice !== offTopic;
        const answers = { topic, ...(onTopic || entry.matched.length ? await ask(text, detailQuestions) : {}) };
        const verdict = {
          topic: acceptedTopic(answers, { x: entry.item.x, minimum }),
          format: answers.format?.choice ?? null,
          priority: answers.format?.choice === 'feature' ? 'normal' : answers.priority?.confidence >= minimum && rank[answers.priority.choice] !== undefined ? answers.priority.choice : null,
          significance: significanceTag(answers, minimum),
          version: classificationVersion,
          at: new Date().toISOString(),
        };
        verdicts[entry.key] = verdict;
        apply(entry, verdict);
      } catch (error) {
        classifyError ??= error;
      }
    }));
    await checkpoint();
  }
  if (classifyError) failures.push(`headlines classifier: ${classifyError.message}`);

  const candidates = [...seen.values()]
    .filter(entry => entry.matched.length && verdicts[entry.key] && !state[entry.key] && !entry.duplicate)
    .sort((a, b) => Number(Boolean(a.item.x)) - Number(Boolean(b.item.x)) || rank[a.priority ?? 'normal'] - rank[b.priority ?? 'normal'] || b.item.stamp - a.item.stamp);
  const byKey = new Map(candidates.map(entry => [entry.key, entry]));
  const { decisions, error: dedupeError } = await dedupeCandidates(candidates.map(entry => ({ ...entry.item, key: entry.key })), published, { ask, minimum, historyAvailable });
  for (const decision of decisions) {
    const entry = byKey.get(decision.key);
    if (decision.status === 'duplicate') {
      entry.duplicate = true;
      if (verdicts[entry.key]) verdicts[entry.key].duplicate = true;
    } else if (decision.status === 'deferred') entry.deferred = true;
  }
  if (dedupeError) failures.push(`headlines dedupe: ${dedupeError}`);
  await recordDedupe(decisions).catch(error => failures.push(`headlines dedupe log: ${error.message}`));

  await checkpoint();

  const publishable = [...seen.values()].filter(entry => entry.matched.length && verdicts[entry.key] && !state[entry.key] && !entry.duplicate && !entry.deferred);
  await Promise.all(publishable.map(async entry => { entry.item.url = await resolveGoogleNews(entry.item.url); }));
  // A Bloomberg story waits up to `syndication_wait_minutes` for Yahoo's readable copy, then publishes with its own link.
  const wait = (config.syndication_wait_minutes ?? 10) * 60000;
  await Promise.all(publishable.filter(entry => walled(entry.item.url)).map(async entry => {
    const copy = await readableCopy(entry.item.title, entry.item.url, resolveGoogleNews).catch(error => { failures.push(`headlines syndication: ${error.message}`); return null; });
    if (copy) entry.item.url = copy;
    else if (Date.now() - entry.item.stamp < wait) entry.held = true;
  }));

  for (const { key, item, matched, priority, significance } of publishable.filter(entry => !entry.held)) {
    const best = matched.reduce((top, topic) => (rank[topic.priority ?? 'normal'] < rank[top.priority ?? 'normal'] ? topic : top), matched[0]);
    const labels = matched.map(topic => topic.label ?? topic.id).join(', ');
    const when = new Date(item.stamp).toISOString().replace('T', ' ').slice(0, 16);
    events.push({
      key,
      title: item.title,
      summary: item.summary,
      body: `Matched watchlist: ${labels}. ${item.x ? `Post by ${item.publisher} on X` : `Headline and link as published by ${item.publisher}`} at ${when} UTC; topic classification establishes coverage of a topic, not the accuracy of the claim.`,
      source: item.publisher,
      url: item.url,
      image_url: item.image,
      published_at: new Date(item.stamp).toISOString(),
      category: best.category ?? 'general',
      priority: priority ?? best.priority ?? 'normal',
      tickers: [],
      tags: [...new Set(['deterministic', item.x ? 'x' : 'headlines', ...matched.map(topic => topic.id), ...(significance ? [significance] : [])])],
    });
  }

  return { events: balanceHeadlines(events), failures };
}
