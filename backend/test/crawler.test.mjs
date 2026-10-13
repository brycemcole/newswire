import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createCrawler } from '../../scripts/crawler/crawler.mjs';
import { main } from '../../scripts/crawler/run.mjs';
import { isPublicAddress, fetchPublicText, robotsAllows, validatePublicUrl } from '../../scripts/crawler/network.mjs';
import { articleText, buildSearchQuestions, canonicalUrl, extractLinks, parseFeed, requestUrl } from '../../scripts/crawler/sources.mjs';
import { collectScrolledLinks } from '../../scripts/crawler/browser.mjs';

const publicLookup = async () => [{ address: '93.184.216.34', family: 4 }];
const baseConfig = extra => ({ userAgent: 'NewswireTestCrawler', feeds: [], seeds: [], topics: [], discovery: { googleNews: false, gdelt: false },
  limits: { maxPages: 10, maxDepth: 2, maxBytes: 100000, timeoutMs: 1000, maxRedirects: 3, maxRetries: 1, maxLinksPerPage: 10,
    concurrencyPerDomain: 1, maxConcurrency: 3, delayMsPerDomain: 0, maxExploreFraction: 0.3, revisitFeedMs: 0, revisitSearchMs: 0, revisitPageMs: 0 }, ...extra });
const response = (body, contentType = 'text/html') => new Response(body, { status: 200, headers: { 'content-type': contentType } });

test('URL safety pins validated public DNS and rejects local, mapped and special addresses', async () => {
  assert.equal(isPublicAddress('93.184.216.34'), true);
  for (const address of ['127.0.0.1', '10.1.2.3', '169.254.1.1', '::1', '::ffff:7f00:1', '2001:db8::1', 'fe80::1']) assert.equal(isPublicAddress(address), false, address);
  await assert.rejects(validatePublicUrl('http://127.0.0.1/'), /non-public/);
  await assert.rejects(validatePublicUrl('http://example.test/', async () => [{ address: '8.8.8.8' }, { address: '192.168.1.3' }]), /non-public/);
  const requested = [];
  const fetchImpl = async (_url, options) => { requested.push(options.pinnedAddresses); return response('ok', 'text/plain'); };
  await fetchPublicText('https://example.test/', { fetchImpl, resolve: publicLookup });
  assert.equal(requested[0][0].address, '93.184.216.34');
});

test('robots groups merge agents, honor longest path and prefer allow ties', () => {
  const robots = 'User-agent: *\nDisallow: /private\n\nUser-agent: NewswireTestCrawler\nDisallow: /private/research\nAllow: /private/research/public\n';
  assert.equal(robotsAllows(robots, 'https://example.test/private/a', 'NewswireTestCrawler'), true);
  assert.equal(robotsAllows(robots, 'https://example.test/private/research/x', 'NewswireTestCrawler'), false);
  assert.equal(robotsAllows(robots, 'https://example.test/private/research/public/x', 'NewswireTestCrawler'), true);
  assert.equal(robotsAllows('User-agent: *\nDisallow: /blocked\n', 'https://example.test/ok'), true);
});

test('malformed links are isolated and confirmation questions use compact subjects with provenance', () => {
  const links = extractLinks('<a href="http://[bad">broken useful malformed destination anchor</a><a href="/ok">A real economic report on rates</a>', 'https://example.test/', 10);
  assert.equal(links.length, 1);
  assert.match(links[0].url, /ok$/);
  const questions = buildSearchQuestions({ event_id: 'event-1', title: 'Federal Reserve announces major policy decision after long meeting' }, Date.parse('2026-10-12T12:00:00Z'));
  assert.deepEqual(questions.map(question => question.search_role), ['confirm', 'contradict', 'explore']);
  assert.ok(questions.every(question => question.event_id === 'event-1' && question.query.length < 180));
  assert.equal(articleText('<meta property="article:published_time" content="2026-10-12T12:00:00Z"><article>Report</article>').published_at, '2026-10-12T12:00:00.000Z');
  assert.equal(articleText('<article>Report</article>').published_at, null);
  assert.equal(requestUrl('http://www.example.test/a?utm_source=x'), 'http://www.example.test/a');
});

test('robots retrieval failure fails closed while a missing robots file permits fetch', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'crawler-robots-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const config = baseConfig({ seeds: [{ name: 'seed', url: 'https://source.example.test/feed', kind: 'feed' }] });
  let feedCalls = 0;
  const failed = createCrawler({ config, stateFile: join(dir, 'failed.json'), resolve: publicLookup, fetchImpl: async url => {
    if (url.endsWith('/robots.txt')) return new Response('', { status: 503 });
    feedCalls += 1; return response('<rss></rss>', 'application/rss+xml');
  }, archive: async () => {} });
  const deferred = await failed.runOnce();
  assert.equal(feedCalls, 0);
  assert.equal(deferred.health, 'unhealthy');
  assert.match(deferred.failures[0].error, /HTTP 503/);

  const allowed = createCrawler({ config, stateFile: join(dir, 'missing.json'), resolve: publicLookup, fetchImpl: async url => {
    if (url.endsWith('/robots.txt')) return new Response('', { status: 404 });
    feedCalls += 1; return response('<rss></rss>', 'application/rss+xml');
  }, archive: async () => {} });
  assert.equal((await allowed.runOnce()).processed, 1);
  assert.equal(feedCalls, 1);
});

test('feed seed follows linked article, archives revisions and canonical URL duplicates with provenance', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'crawler-e2e-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const feedUrl = 'https://feeds.example.test/rss', articleUrl = 'https://publisher.example.test/story?utm_source=feed';
  let articleBody = 'The Federal Reserve announced its policy decision today. '.repeat(12);
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push(url);
    if (url.endsWith('/robots.txt')) return response('User-agent: *\nAllow: /', 'text/plain');
    if (url === feedUrl) return response(`<rss><channel><item><title>Federal Reserve announces a policy decision</title><link>${articleUrl}</link><guid>release-1</guid><pubDate>Mon, 12 Oct 2026 12:00:00 GMT</pubDate><description>Policy rates remain unchanged following the scheduled meeting.</description></item><item><title>Same release duplicate</title><link>https://publisher.example.test/story?utm_medium=copy</link><guid>release-copy</guid><pubDate>Mon, 12 Oct 2026 12:00:00 GMT</pubDate></item></channel></rss>`, 'application/rss+xml');
    if (url === 'https://publisher.example.test/story') return response(`<html><head><title>Federal Reserve policy decision</title><meta name="description" content="Rates held steady."></head><body><article><h1>Federal Reserve policy decision</h1><p>${articleBody}</p></article><a href="http://[broken">A malformed link title that should not crash crawler</a></body></html>`);
    return response('<html><body>unrelated small page</body></html>');
  };
  const config = baseConfig({ feeds: [{ name: 'Fed source', url: feedUrl, topics: ['rates'] }], limits: { ...baseConfig().limits, maxPages: 10 } });
  const archived = [];
  let clock = Date.parse('2026-10-12T13:00:00Z');
  const crawler = createCrawler({ config, stateFile: join(dir, 'state.json'), fetchImpl, resolve: publicLookup, now: () => clock, archive: async items => archived.push(...items) });
  const first = await crawler.runOnce();
  assert.equal(first.processed, 2);
  assert.equal(first.added_stories, 1);
  assert.equal(first.unique_findings, 1);
  assert.equal(archived.length, 1);
  assert.ok(archived[0].body.includes('Federal Reserve announced'));
  assert.equal(archived[0].stamp, Date.parse('2026-10-12T12:00:00Z'));
  assert.equal(archived[0].revision_id.length, 64);
  assert.ok(archived[0].provenance.includes('Fed source'));
  assert.equal(canonicalUrl(archived[0].url), 'https://publisher.example.test/story');

  articleBody = 'The Federal Reserve changed its policy guidance in a revised release. '.repeat(12);
  clock += 1000;
  const second = await crawler.runOnce();
  assert.equal(second.revisions, 1, JSON.stringify({ first: { processed: first.processed, revisions: first.revisions }, second: { processed: second.processed, revisions: second.revisions, failures: second.failures, queued: second.queued }, calls }));
  assert.equal(second.added_stories, 0);
  assert.equal(second.stories.length, 1);
  assert.equal(second.stories[0].versions.length, 3);
  assert.ok(calls.filter(url => url === 'https://publisher.example.test/story').length >= 2);
});

test('CLI question, state and report options drive an injected run and preserve safe unknown dates', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'crawler-cli-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const configFile = join(dir, 'config.json'), questionsFile = join(dir, 'questions.json'), stateDir = join(dir, 'state'), reportFile = join(dir, 'report.json');
  const feedUrl = 'https://feeds.example.test/rss';
  await writeFile(configFile, JSON.stringify(baseConfig({ feeds: [{ name: 'Fixture', url: feedUrl }], discovery: { googleNews: true, gdelt: false }, limits: { ...baseConfig().limits, maxPages: 10 } })));
  await writeFile(questionsFile, JSON.stringify([{ id: 'q-123', query: 'confirm CPI release', reason: 'confirmation', status: 'open', created_at: '2026-10-12T00:00:00Z', event_id: 'evt-2' }]));
  const calls = [];
  const fetchImpl = async url => {
    calls.push(url);
    if (url.endsWith('/robots.txt')) return response('User-agent: *\nAllow: /', 'text/plain');
    if (url === feedUrl) return response('<rss><item><title>Unknown date story about rate policy</title><link>https://publisher.example.test/unknown</link><guid>unknown</guid></item></rss>', 'application/rss+xml');
    if (url.includes('news.google.com')) return response('<rss></rss>', 'application/rss+xml');
    if (url === 'https://publisher.example.test/unknown') return response(`<article><h1>Unknown date story about rate policy</h1><p>${'A useful report about economic policy and market conditions. '.repeat(10)}</p></article>`);
    return response('<rss></rss>', 'application/rss+xml');
  };
  const result = await main(['--once', `--config=${configFile}`, `--questions-file=${questionsFile}`, `--state-dir=${stateDir}`, `--report-file=${reportFile}`], { log() {} }, { fetchImpl, resolve: publicLookup, archive: async () => {} });
  assert.ok(calls.some(url => { const parsed = new URL(url); return parsed.searchParams.get('q')?.includes('confirm CPI release') || parsed.searchParams.get('query')?.includes('confirm CPI release'); }), JSON.stringify(calls));
  assert.ok(result.questions_attempted >= 1);
  const savedState = JSON.parse(await readFile(join(stateDir, 'crawler-state.json'), 'utf8'));
  assert.ok(Object.values(savedState.questions).some(question => question.id === 'q-123'));
  const report = JSON.parse(await readFile(reportFile, 'utf8'));
  assert.equal(report.health, 'healthy');
  assert.equal(report.unique_findings, 1);
  assert.equal(result.stories[0].published_at, null);
  assert.equal(result.stories[0].stamp, undefined);
});

test('dry run validates CLI without writing state or report files', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'crawler-dry-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const configFile = join(dir, 'config.json');
  await writeFile(configFile, JSON.stringify(baseConfig()));
  const result = await main(['--once', '--dry-run', `--config=${configFile}`, `--state-dir=${join(dir, 'state')}`, `--report-file=${join(dir, 'report.json')}`], { log() {} }, { resolve: publicLookup, fetchImpl: async () => response('<rss></rss>', 'application/rss+xml') });
  assert.equal(result.dry_run, true);
  await assert.rejects(readFile(join(dir, 'state', 'crawler-state.json')));
  await assert.rejects(readFile(join(dir, 'report.json')));
});

test('bounded browser scrolling adds newly rendered links, stops when idle and blocks cross-host requests', async () => {
  const routes = [], requests = [], anchors = [[{ url: 'https://press.example.test/a', title: 'Initial public release' }]];
  let scrolls = 0;
  const fakeAnchor = link => ({ href: link.url, innerText: link.title, getAttribute: () => '' });
  const route = { request() { return requests[requests.length - 1]; }, abort: async () => routes.push('abort'), continue: async () => routes.push('continue') };
  const page = {
    route: async (_pattern, handler) => { for (const [url, type] of [['https://press.example.test/story', 'document'], ['https://127.0.0.1/private', 'fetch'], ['https://other.example.test/ad.js', 'script'], ['https://press.example.test/logo.png', 'image']]) { requests.push({ url: () => url, resourceType: () => type }); await handler(route); } },
    goto: async () => {},
    locator: () => ({ evaluateAll: async callback => callback(anchors.flat().map(fakeAnchor)) }),
    evaluate: async () => { scrolls += 1; if (scrolls === 1) anchors.push([{ url: 'https://press.example.test/b', title: 'Later public release' }]); },
    waitForTimeout: async () => {}
  };
  const browserFactory = async () => ({ newContext: async () => ({ newPage: async () => page, close: async () => {} }), close: async () => {} });
  const links = await collectScrolledLinks('https://press.example.test/', { browserFactory, allowedDomains: ['press.example.test'], resolve: publicLookup, idleMs: 1, maxScrolls: 5 });
  assert.deepEqual(links.map(link => link.url), ['https://press.example.test/a', 'https://press.example.test/b']);
  assert.equal(scrolls, 2);
  assert.deepEqual(routes, ['continue', 'abort', 'abort', 'abort']);
});
