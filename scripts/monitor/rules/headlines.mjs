import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { getText } from '../fetch.mjs';
import { ask } from '../jev.mjs';
import { recent } from '../publish.mjs';
import { load } from '../state.mjs';
import { timeline } from '../x.mjs';
import { readableCopy, walled } from '../syndication.mjs';

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
};
export const duplicateQuestion = {
  duplicate: {
    criteria: {
      same: 'Covers the same underlying story as one already published: another outlet, different wording, extra detail, reactions, reviews, or incremental updates to it.',
      new: 'A distinct event, or a major new turn that would deserve its own headline: a decision that changes the outcome, such as talks becoming a signed deal, a halt, ruling, resignation, or collapse.',
    },
    instructions: 'Would publishing the new story repeat news already on the wire?',
  },
};
const classificationVersion = createHash('sha256').update(JSON.stringify({ topics, topicQuestion, detailQuestions })).digest('hex').slice(0, 12);
const formats = new Set(config.skip_sections ?? ['video', 'videos', 'live', 'live-updates', 'live-news', 'opinion', 'opinions', 'briefing', 'podcast', 'podcasts', 'newsletters', 'gallery', 'pictures', 'interactive']);

// Formats Jev always rejects, decided from the URL alone: clips, live blogs, opinion, briefings, galleries.
// X posts mostly in another script are local promos, never US news.
export function prefiltered(item) {
  let segments = [];
  try { segments = new URL(item.url).pathname.toLowerCase().split('/'); } catch { return false; }
  if (!item.x && segments.some(segment => formats.has(segment))) return true;
  if (item.x) {
    const letters = item.title.match(/\p{L}/gu) ?? [];
    return letters.length > 0 && letters.filter(letter => /[a-z]/i.test(letter)).length / letters.length < 0.5;
  }
  return false;
}

const stopwords = new Set('the and for with from that this after over into amid about says said will its his her their has have had are was were but not new more than out off who what how why when year years report reports'.split(' '));

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

function words(text) {
  return new Set(comparable(text).split(' ').filter(word => word.length > 2 && !stopwords.has(word)).map(word => word.replace(/(?<=\w{3})s$/, '')));
}

function shared(a, b) {
  let count = 0;
  for (const word of a) if (b.has(word)) count += 1;
  return count;
}

function similar(item, published) {
  return published
    .map(story => ({ story, shared: shared(item.words, story.words), jaccard: shared(item.words, story.words) / (new Set([...item.words, ...story.words]).size || 1) }))
    .filter(match => match.shared >= 2)
    .sort((a, b) => b.jaccard - a.jaccard)
    .slice(0, 5);
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

export async function run() {
  const events = [];
  const failures = [];
  const windowMs = (config.window_minutes ?? 30) * 60000;
  const seen = new Map();

  const sources = [
    ...config.feeds.map(feed => ({ ...feed, via: feed.via ?? [] })),
    ...topics.filter(topic => topic.query).map(topic => ({ name: `Google News: ${topic.label}`, url: googleNewsUrl(topic.query), via: [topic.id] })),
  ];

  const settled = await Promise.allSettled(sources.map(async source => {
    const xml = await getText(source.url);
    if (!/<(?:rss|feed)\b/i.test(xml)) throw new Error('Expected an RSS or Atom feed');
    return parseFeed(xml, source.name).map(item => ({ ...item, via: source.via, windowMs: (source.window_minutes ?? config.window_minutes ?? 30) * 60000 }));
  }));
  if (config.x !== false) {
    sources.push({ name: 'X Following' });
    settled.push(...await Promise.allSettled([timeline().then(posts => posts.map(item => ({ ...item, via: [] })))]));
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
  const nearIdentical = config.near_identical ?? 0.6;
  let published = [];
  try {
    published = (await recent(config.dedupe_hours ?? 24)).map(story => ({ ...story, words: words(story.title) }));
  } catch (error) {
    failures.push(`headlines dedupe: ${error.message}`);
  }
  const titles = new Set();
  for (const entry of seen.values()) {
    entry.item.words = words(entry.item.title);
    const title = comparable(entry.item.title);
    if (state[entry.key]) continue;
    if (titles.has(title) || similar(entry.item, published)[0]?.jaccard >= nearIdentical) entry.duplicate = true;
    titles.add(title);
  }
  const apply = (entry, verdict) => {
    const topic = classified.find(candidate => candidate.id === verdict.topic);
    if (!entry.matched.length && topic) entry.matched.push(topic);
    entry.priority = verdict.priority;
    if (verdict.duplicate) entry.duplicate = true;
  };
  for (const entry of seen.values()) if (verdicts[entry.key]) apply(entry, verdicts[entry.key]);
  const pending = [...seen.values()].filter(entry => !state[entry.key] && !verdicts[entry.key] && !entry.duplicate);
  let classifyError;
  for (let start = 0; start < pending.length && !classifyError; start += 8) {
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
          version: classificationVersion,
          at: new Date().toISOString(),
        };
        verdicts[entry.key] = verdict;
        apply(entry, verdict);
      } catch (error) {
        classifyError ??= error;
      }
    }));
  }
  if (classifyError) failures.push(`headlines classifier: ${classifyError.message}`);

  const candidates = [...seen.values()]
    .filter(entry => entry.matched.length && !state[entry.key] && !entry.duplicate)
    .sort((a, b) => Number(Boolean(a.item.x)) - Number(Boolean(b.item.x)) || rank[a.priority ?? 'normal'] - rank[b.priority ?? 'normal'] || b.item.stamp - a.item.stamp);
  let dedupeError;
  for (const entry of candidates) {
    const matches = similar(entry.item, published);
    if (matches[0]?.jaccard >= nearIdentical) {
      entry.duplicate = true;
      continue;
    }
    if (matches.length) {
      try {
        const list = matches.map(match => `- ${match.story.title}`).join('\n');
        const answer = (await ask(`New story: ${entry.item.title}\n\nAlready published:\n${list}`, duplicateQuestion)).duplicate;
        if (answer.choice !== 'new' || answer.confidence < minimum) {
          entry.duplicate = true;
          if (verdicts[entry.key]) verdicts[entry.key].duplicate = true;
          continue;
        }
      } catch (error) {
        dedupeError ??= error;
      }
    }
    published.push({ title: entry.item.title, source: entry.item.publisher, words: entry.item.words });
  }
  if (dedupeError) failures.push(`headlines dedupe: ${dedupeError.message}`);

  const cacheWindowMs = Math.max(windowMs, ...config.feeds.map(feed => (feed.window_minutes ?? config.window_minutes ?? 30) * 60000));
  const kept = Object.fromEntries(Object.entries(verdicts).filter(([, verdict]) => Date.now() - Date.parse(verdict.at) < 2 * cacheWindowMs));
  await mkdir(dirname(verdictsFile), { recursive: true, mode: 0o700 });
  await writeFile(verdictsFile, `${JSON.stringify(kept)}\n`, { mode: 0o600 });

  const publishable = [...seen.values()].filter(entry => entry.matched.length && !state[entry.key] && !entry.duplicate);
  await Promise.all(publishable.map(async entry => { entry.item.url = await resolveGoogleNews(entry.item.url); }));
  // A Bloomberg story waits up to `syndication_wait_minutes` for Yahoo's readable copy, then publishes with its own link.
  const wait = (config.syndication_wait_minutes ?? 10) * 60000;
  await Promise.all(publishable.filter(entry => walled(entry.item.url)).map(async entry => {
    const copy = await readableCopy(entry.item.title, entry.item.url, resolveGoogleNews).catch(error => { failures.push(`headlines syndication: ${error.message}`); return null; });
    if (copy) entry.item.url = copy;
    else if (Date.now() - entry.item.stamp < wait) entry.held = true;
  }));

  for (const { key, item, matched, priority } of publishable.filter(entry => !entry.held)) {
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
      tags: [...new Set(['deterministic', item.x ? 'x' : 'headlines', ...matched.map(topic => topic.id)])],
    });
  }

  return { events: balanceHeadlines(events), failures };
}
