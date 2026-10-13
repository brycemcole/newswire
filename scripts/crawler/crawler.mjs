import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { lookup } from 'node:dns/promises';
import { collectScrolledLinks, playwrightFactory } from './browser.mjs';
import { fetchPublicText, robotsAllows, validatePublicUrl } from './network.mjs';
import { articleText, buildSearchQuestions, canonicalUrl, extractLinks, parseFeed, requestUrl, searchUrls, stableId } from './sources.mjs';
import { readState, writeState } from './state.mjs';

const here = new URL('.', import.meta.url);
const defaults = {
  configFile: new URL('./config.json', here).pathname,
  stateFile: join(homedir(), '.config', 'newswire', 'crawler-state.json'),
};

export async function loadConfig(file = defaults.configFile) { return JSON.parse(await readFile(file, 'utf8')); }

export function createCrawler({ config, stateFile = defaults.stateFile, fetchImpl, resolve = lookup, archive = null,
  browserFactory = null, now = () => Date.now(), logger = () => {} } = {}) {
  if (!config || !Array.isArray(config.feeds) || !config.limits) throw new Error('Crawler config with feeds and limits is required');
  const limit = config.limits;
  const domainQueues = new Map();
  const robotsCache = new Map();
  const crawlDomain = async (url, operation) => {
    const host = new URL(url).hostname;
    let slot = domainQueues.get(host);
    if (!slot) { slot = { active: 0, pending: [], nextAt: 0 }; domainQueues.set(host, slot); }
    if (slot.active >= Math.max(1, limit.concurrencyPerDomain ?? 1)) await new Promise(resolveWait => slot.pending.push(resolveWait));
    slot.active += 1;
    try {
      const wait = slot.nextAt - now();
      if (wait > 0) await new Promise(resolveWait => setTimeout(resolveWait, wait));
      slot.nextAt = now() + Math.max(0, limit.delayMsPerDomain ?? 0);
      return await operation();
    } finally { slot.active -= 1; slot.pending.shift()?.(); }
  };
  const safeFetch = async (url, { robotsDocument = false } = {}) => fetchPublicText(url, { fetchImpl, resolve, timeoutMs: limit.timeoutMs, maxBytes: limit.maxBytes,
    maxRedirects: limit.maxRedirects, userAgent: config.userAgent, allowNotFound: robotsDocument,
    requestWrapper: (target, request) => crawlDomain(target, request),
    beforeRequest: async target => {
      if (robotsDocument || new URL(target).pathname === '/robots.txt') return true;
      const origin = new URL(target).origin;
      if (!robotsCache.has(origin)) robotsCache.set(origin, safeFetch(`${origin}/robots.txt`, { robotsDocument: true }).then(result => ({ text: result.text })).catch(error => ({ error })));
      const robots = await robotsCache.get(origin);
      if (robots.error) throw robots.error;
      return robotsAllows(robots.text, target, config.userAgent);
    } });
  const allowed = safeFetch;

  async function runOnce({ dryRun = false, scroll = false } = {}) {
    const state = await readState(stateFile), start = now();
    state.domains ??= {};
    const queuedKeys = new Set(state.queue.filter(task => ['queued', 'working'].includes(task.status)).map(task => task.key ?? `${task.kind}\n${canonicalUrl(task.url)}\n${task.query ?? ''}`));
    const addTask = task => {
      const url = requestUrl(task.url), canonical = canonicalUrl(task.url);
      if (!url || !canonical) return false;
      const key = `${task.kind}\n${canonical}\n${task.query ?? ''}`;
      const interval = task.revisitMs ?? (task.kind === 'feed' ? limit.revisitFeedMs ?? 15 * 60000 : task.kind === 'search' ? limit.revisitSearchMs ?? 2 * 3600000 : limit.revisitPageMs ?? 24 * 3600000);
      if (queuedKeys.size >= (limit.maxQueue ?? 1000) || queuedKeys.has(key) || (state.visited[key] && now() - state.visited[key].atMs < interval)) return false;
      queuedKeys.add(key); state.queue.push({ ...task, url, key, status: 'queued', queued_at: new Date(start).toISOString() }); return true;
    };
    for (const feed of config.feeds) addTask({ kind: 'feed', url: feed.url, source: feed.name, topics: feed.topics ?? [], depth: 0, provenance: [feed.name] });
    for (const seed of config.seeds ?? []) addTask({ kind: seed.kind === 'search' ? 'search' : 'page', url: seed.url, query: seed.query, source: seed.name ?? 'Configured seed', topics: seed.topics ?? [], depth: 0, provenance: [seed.name ?? 'Configured seed'] });
    for (const topic of (config.topics ?? []).slice(0, Math.floor((limit.maxPages ?? 10) * (limit.maxExploreFraction ?? 0.3)))) {
      const url = searchUrls(topic, config.discovery)[0];
      if (url) addTask({ kind: 'search', url, query: topic, search_role: 'explore', source: 'Topic discovery', topics: [topic], depth: 0, provenance: ['Topic discovery'] });
    }
    if (config.questionsFile) {
      let questions;
      try { questions = JSON.parse(await readFile(config.questionsFile, 'utf8')); } catch (error) { if (error.code === 'ENOENT') questions = []; else throw error; }
      if (!Array.isArray(questions)) throw new Error('Questions file must contain a JSON array');
      for (const question of questions) {
        if (!question || typeof question.id !== 'string' || typeof question.query !== 'string' || !question.query.trim() || question.status !== 'open') continue;
        const givenRole = question.search_role ?? question.mode;
        const role = ['confirm', 'confirmation'].includes(givenRole) ? 'confirm' : ['contradict', 'contradiction'].includes(givenRole) ? 'contradict' : givenRole === 'explore' ? 'explore'
          : /contradict|refut|deny|disagree/i.test(question.reason ?? '') ? 'contradict' : /confirm|corroborat|verify/i.test(question.reason ?? '') ? 'confirm' : 'explore';
        state.questions[question.id] ??= { ...question, search_role: role, budget_group: question.event_id ?? question.id };
        for (const url of searchUrls(question.query, config.discovery)) addTask({ kind: 'search', url, query: question.query, search_role: role,
          question_id: question.id, event_id: question.event_id ?? null, source: 'Parent research question', topics: [], depth: 0,
          provenance: [`question:${question.id}`, `role:${role}`] });
      }
    }
    const pages = new Map(Object.entries(state.stories));
    const archiveByUrl = new Map(), failures = [], attemptedQuestions = new Set(), newFindingUrls = new Set();
    let processed = 0, addedStories = 0, revisions = 0, exploreProcessed = 0;
    const maxPages = Math.max(1, limit.maxPages ?? 24);
    const exploreBudget = Math.floor(maxPages * (limit.maxExploreFraction ?? 0.3));
    while (processed < maxPages) {
      const eligible = state.queue.filter(task => task.status === 'queued' && (!task.not_before || task.not_before <= now())
        && (state.domains[new URL(task.url).hostname]?.nextAt ?? 0) <= now());
      const take = Math.min(maxPages - processed, Math.max(1, limit.maxConcurrency ?? 3));
      const exploreReserve = Math.max(0, Math.min(exploreBudget - exploreProcessed, Math.max(1, Math.floor(take * (limit.maxExploreFraction ?? 0.3))), take));
      const explore = eligible.filter(task => !task.question_id && task.kind === 'search');
      const questions = eligible.filter(task => !explore.includes(task));
      const batch = [...explore.slice(0, exploreReserve), ...questions.slice(0, Math.max(0, take - exploreReserve)), ...explore.slice(exploreReserve, take)].slice(0, take);
      if (!batch.length) break;
      exploreProcessed += batch.filter(task => explore.includes(task)).length;
      for (const task of batch) task.status = 'working';
      if (!dryRun) await writeState(stateFile, state);
      const outcomes = await Promise.all(batch.map(async task => {
        try { return { task, data: await allowed(task.url) }; }
        catch (error) { return { task, error }; }
      }));
      for (const { task, data, error } of outcomes) {
        processed += 1;
        task.status = 'done'; task.finished_at = new Date(now()).toISOString();
        state.visited[task.key] = { status: error ? 'failed' : data ? 'done' : 'robots-blocked', at: task.finished_at, atMs: now(), error: error?.message };
        if (task.question_id && state.questions[task.question_id]) {
          attemptedQuestions.add(task.question_id);
          const question = state.questions[task.question_id]; question.attempts = (question.attempts ?? 0) + 1;
          question.last_attempt_at = task.finished_at; question.last_status = error ? 'failed' : data ? 'searched' : 'robots-blocked';
        }
        if (error) {
          failures.push({ url: task.url, error: error.message });
          const host = new URL(task.url).hostname, domainState = state.domains[host] ??= { failures: 0, nextAt: 0 };
          domainState.failures = Math.min(12, domainState.failures + 1);
          const backoffMs = error.retryAfterMs ?? Math.min(60 * 60000, 1000 * 2 ** Math.min(domainState.failures, 10));
          domainState.nextAt = now() + backoffMs;
          domainState.last_error = error.message; domainState.last_failed_at = new Date(now()).toISOString();
          const retryable = error.status === 401 || error.status === 403 || error.status === 429 || error.status >= 500 || /timeout|network|fetch failed/i.test(error.message);
          if (retryable && (task.attempts ?? 0) < (limit.maxRetries ?? 2)) {
            queuedKeys.delete(task.key);
            addTask({ ...task, revisitMs: 0, attempts: (task.attempts ?? 0) + 1, not_before: now() + (error.retryAfterMs ?? 1000 * 2 ** (task.attempts ?? 0)) });
          }
          continue;
        }
        if (!data) {
          failures.push({ url: task.url, error: 'Blocked by robots.txt' });
          continue;
        }
        const domainState = state.domains[new URL(task.url).hostname];
        if (domainState) { domainState.failures = 0; domainState.nextAt = 0; delete domainState.last_error; }
        const isFeed = task.kind === 'feed' || /(?:rss|atom|xml)/i.test(data.contentType) || /<(?:rss|feed)\b/i.test(data.text.slice(0, 1000));
        const foundStories = isFeed ? parseFeed(data.text, { name: task.source, topics: task.topics }) : [];
        for (const item of foundStories) Object.assign(item, {
          via: [...new Set([...(item.via ?? []), ...(task.provenance ?? [])])], query: task.query ?? null,
          question_id: task.question_id ?? null, event_id: task.event_id ?? null, search_role: task.search_role ?? null,
        });
        const extracted = isFeed ? [] : articleText(data.text);
        const depth = task.depth ?? 0;
        if (!isFeed && (depth > 0 || task.kind === 'page') && extracted.body.length >= 400) {
          const title = extracted.title || task.title || task.query || new URL(data.url).hostname;
          const candidateDate = extracted.published_at ?? task.published_at ?? null;
          const candidateMs = candidateDate ? Date.parse(candidateDate) : NaN;
          const publishedAt = Number.isFinite(candidateMs) && candidateMs <= now() ? new Date(candidateMs).toISOString() : null;
          const story = { url: canonicalUrl(data.url), title, summary: extracted.summary, body: extracted.body,
            publisher: task.source ?? new URL(data.url).hostname, published_at: publishedAt, publication_status: publishedAt ? 'known' : 'unknown', via: task.provenance ?? [],
            discovered_from: task.parent_url ?? null, search_role: task.search_role ?? null, event_id: task.event_id ?? null, question_id: task.question_id ?? null,
            query: task.query ?? null, observed_at: new Date(now()).toISOString() };
          foundStories.push(story);
        }
        for (const item of foundStories) {
          const sourceUrl = requestUrl(item.url);
          item.url = canonicalUrl(item.url);
          if (!item.url) continue;
          const content_hash = stableId(`${item.title}\n${item.summary ?? ''}\n${item.body ?? ''}`);
          const duplicateInRun = archiveByUrl.get(item.url);
          if (duplicateInRun) {
            duplicateInRun.via = [...new Set([...duplicateInRun.via, ...(item.via ?? [])])];
            duplicateInRun.provenance = [...new Set([...duplicateInRun.provenance, ...(item.via ?? [])])];
            if ((item.body?.length ?? 0) > (duplicateInRun.body?.length ?? 0)) {
              Object.assign(duplicateInRun, item);
            } else continue;
          }
          if (task.kind !== 'page' && (task.depth ?? 0) < (limit.maxDepth ?? 2)) addTask({ kind: 'page', url: sourceUrl, title: item.title, published_at: item.published_at,
            source: item.publisher ?? task.source ?? new URL(item.url).hostname, topics: item.topics ?? task.topics ?? [], depth: (task.depth ?? 0) + 1,
            query: task.query, question_id: task.question_id, provenance: [...(task.provenance ?? []), `story:${task.url}`], parent_url: task.url,
            search_role: task.search_role, event_id: task.event_id });
          const id = stableId(item.url);
          const prior = state.stories[id];
          const knownPublishedAt = item.published_at ?? prior?.published_at ?? archiveByUrl.get(item.url)?.published_at ?? null;
          if (!prior) { state.stories[id] = { id, ...item, content_hash, versions: [{ content_hash, observed_at: item.observed_at ?? new Date(now()).toISOString(), title: item.title, summary: item.summary ?? '', body: item.body ?? '' }], provenance: [...new Set(item.via ?? [])] }; addedStories += 1; newFindingUrls.add(item.url); }
          else if (prior.content_hash !== content_hash && !(prior.body && !item.body)) { prior.versions.push({ content_hash, observed_at: new Date(now()).toISOString(), title: item.title, summary: item.summary ?? '', body: item.body ?? '' }); Object.assign(prior, item, { content_hash }); revisions += 1; newFindingUrls.add(item.url); }
          else prior.provenance = [...new Set([...(prior.provenance ?? []), ...(item.via ?? [])])];
          const record = state.stories[id];
          const publishedMs = knownPublishedAt ? Date.parse(knownPublishedAt) : NaN;
          const validStamp = Number.isFinite(publishedMs) && publishedMs <= now() && publishedMs >= now() - 7 * 86400000 ? publishedMs : null;
          const archiveRecord = { title: item.title, summary: item.summary ?? item.body?.slice(0, 3000) ?? '', body: item.body ?? '', publisher: item.publisher,
            url: item.url, guid: item.guid ?? item.url, stamp: validStamp, published_at: Number.isFinite(publishedMs) ? new Date(publishedMs).toISOString() : null,
            observed_at: item.observed_at ?? new Date(now()).toISOString(), publication_status: validStamp ? 'known' : 'unknown', provenance: item.via ?? [], via: [...new Set(item.via ?? [])],
            content_hash, revision_id: stableId(`${item.url}\n${content_hash}`) };
          if (!archiveByUrl.has(item.url) || (archiveByUrl.get(item.url).body?.length ?? 0) <= (item.body?.length ?? 0)) archiveByUrl.set(item.url, archiveRecord);
          if (!state.questions[id]) {
            const questions = buildSearchQuestions({ ...item, event_id: item.event_id ?? id }, now(), limit.maxExploreFraction ?? 0.3);
            const all = Object.values(state.questions), explCount = all.filter(q => q.search_role === 'explore').length, nonExpl = all.length - explCount;
            for (const question of questions) {
              if (question.search_role === 'explore' && (explCount + 1) / (nonExpl + 3) > (limit.maxExploreFraction ?? 0.3)) continue;
              state.questions[question.id] = question;
              for (const url of searchUrls(question.query, config.discovery)) addTask({ kind: 'search', url, query: question.query, search_role: question.search_role,
                event_id: question.event_id, question_id: question.id, source: 'Research search', topics: item.topics ?? [], depth: 0, provenance: [question.search_role], parent_url: item.url });
            }
          }
        }
        if (depth < (limit.maxDepth ?? 2)) {
          let links = extractLinks(data.text, data.url, limit.maxLinksPerPage ?? 12);
          if (scroll && browserFactory) {
            try { links = [...links, ...await collectScrolledLinks(data.url, { browserFactory, maxScrolls: limit.maxScrolls, idleMs: limit.scrollIdleMs, timeoutMs: limit.timeoutMs, resolve, allowedDomains: config.browserDomains ?? [] })]; }
            catch (scrollError) { failures.push({ url: data.url, error: `scroll: ${scrollError.message}` }); }
          }
          const currentHost = new URL(data.url).hostname;
          links = links.filter(link => new URL(link.url).hostname === currentHost).slice(0, limit.maxLinksPerPage ?? 12);
          for (const link of links) addTask({ kind: 'page', url: link.url, title: link.title, source: task.source ?? currentHost, topics: task.topics ?? [],
            depth: depth + 1, provenance: [...(task.provenance ?? []), data.url], parent_url: data.url });
        }
      }
      if (!dryRun) await writeState(stateFile, state);
    }
    const archiveItems = [...archiveByUrl.values()];
    if (archiveItems.length && !dryRun) {
      const writeArchive = archive ?? (await import('../../scripts/monitor/headline-archive.mjs')).archiveHeadlines;
      await writeArchive(archiveItems, { now: now() });
    }
    const run = { started_at: new Date(start).toISOString(), finished_at: new Date(now()).toISOString(), processed, added_stories: addedStories,
      revisions, queued: state.queue.filter(task => task.status === 'queued').length, failures: failures.slice(0, 100), dry_run: Boolean(dryRun) };
    state.runs.push(run); state.runs = state.runs.slice(-100);
    if (!dryRun) await writeState(stateFile, state);
    run.findings = addedStories + revisions;
    run.unique_findings = newFindingUrls.size;
    run.questions_attempted = attemptedQuestions.size;
    run.health = failures.length === 0 ? 'healthy' : processed > failures.length ? 'degraded' : 'unhealthy';
    if (config.reportFile && !dryRun) {
      await mkdir(dirname(config.reportFile), { recursive: true, mode: 0o700 });
      await writeFile(config.reportFile, JSON.stringify({ ...run, stories: Object.values(state.stories).map(({ id, url, title, published_at, observed_at, provenance, content_hash }) => ({ id, url, title, published_at, observed_at, provenance, content_hash })), research_questions: Object.values(state.questions) }, null, 2) + '\n', { mode: 0o600 });
    }
    logger(run);
    return { ...run, stories: Object.values(state.stories), research_questions: Object.values(state.questions), state };
  }
  return { runOnce };
}

export async function createDefaultCrawler(options = {}) {
  return createCrawler({ config: await loadConfig(options.configFile), ...options });
}

export { playwrightFactory };
