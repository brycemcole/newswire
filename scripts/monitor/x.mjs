import { execFile } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { promisify } from 'node:util';

const bird = process.env.BIRD_BIN ?? join(homedir(), '.local', 'bin', 'bird');
const loginFile = process.env.BIRD_ENV ?? join(homedir(), '.config', 'bird', 'x.env');
const cacheFile = join(homedir(), '.config', 'newswire', 'x-timeline.json');
const interval = Number(process.env.X_POLL_MINUTES ?? 5) * 60000;
export const accountGroups = [
  ['Bloomberg', 'business'],
  ['markets'],
  ['FT'],
  ['FTMarkets'],
  ['Semafor'],
  ['ReutersBiz', 'WSJmarkets', 'CNBC'],
  ['federalreserve', 'BLS_gov', 'BEA_News', 'SECGov'],
];
const accounts = new Set(accountGroups.flat().map(handle => handle.toLowerCase()));
export const timelineSources = [
  ...accountGroups.map(handles => ({ name: handles.join(', '), args: ['search', accountQuery(handles), '-n', '30'], curated: true })),
  { name: 'For You', args: ['home', '-n', '40'], curated: false },
  { name: 'Explore', args: ['news', '--news-only', '--with-tweets', '--tweets-per-item', '3', '-n', '10'], curated: false, explore: true },
];
const sourceVersion = JSON.stringify(timelineSources);
const publishers = {
  bloomberg: ['Bloomberg', 'bloomberg.com'], business: ['Bloomberg', 'bloomberg.com'], markets: ['Bloomberg', 'bloomberg.com'],
  ft: ['Financial Times', 'ft.com'], ftmarkets: ['Financial Times', 'ft.com'], semafor: ['Semafor', 'semafor.com'],
  reutersbiz: ['Reuters', 'reuters.com'], wsjmarkets: ['Wall Street Journal', 'wsj.com'], cnbc: ['CNBC', 'cnbc.com'],
  federalreserve: ['Federal Reserve', 'federalreserve.gov'], bls_gov: ['Bureau of Labor Statistics', 'bls.gov'],
  bea_news: ['Bureau of Economic Analysis', 'bea.gov'], secgov: ['SEC', 'sec.gov'],
};
export function linkedArticle(item, url) {
  if (!url) return item;
  const publisher = publishers[item.publisher.replace(/^@/, '').toLowerCase()];
  const host = new URL(url).hostname.toLowerCase();
  return publisher && (host === publisher[1] || host.endsWith(`.${publisher[1]}`))
    ? { ...item, url, publisher: publisher[0], x: false } : { ...item, url };
}
export function accountQuery(handles) {
  return `(${handles.map(handle => `from:${handle}`).join(' OR ')}) -filter:retweets -filter:replies`;
}

async function login() {
  const pairs = (await readFile(loginFile, 'utf8')).split('\n').map(line => line.match(/^(AUTH_TOKEN|CT0)=(.+)$/)).filter(Boolean);
  const env = Object.fromEntries(pairs.map(match => [match[1], match[2].trim()]));
  if (!env.AUTH_TOKEN || !env.CT0) throw new Error('X login missing');
  return env;
}

const clean = text => String(text ?? '').replace(/https:\/\/t\.co\/\w+/g, '').replace(/\s+/g, ' ').trim();

export function headline(text) {
  const sentence = text.match(/^(.{40,180}?[.!?])(\s|$)/)?.[1];
  if (sentence) return sentence;
  return text.length > 180 ? `${text.slice(0, 177).replace(/\s+\S*$/, '')}…` : text;
}

export function sourceItems(parsed, source) {
  const records = Array.isArray(parsed) ? parsed : source.explore ? parsed.items ?? [] : parsed.tweets ?? [];
  const tweets = source.explore ? records.flatMap(record => record.tweets ?? []) : records;
  return items(tweets, { curated: source.curated }).map(item => source.curated ? item : { ...item, discovery: source.name });
}

export function items(tweets, { curated = true } = {}) {
  return tweets.flatMap(tweet => {
    const text = clean(tweet.text);
    const stamp = Math.min(Date.parse(tweet.createdAt), Date.now());
    if (!/^[a-z0-9_]{1,15}$/i.test(tweet.author?.username ?? '') || (curated && !accounts.has(tweet.author.username.toLowerCase())) || !tweet.id || tweet.inReplyToStatusId || text.startsWith('RT @') || text.length < 40 || !Number.isFinite(stamp)) return [];
    const quoted = tweet.quotedTweet ? `Quoting @${tweet.quotedTweet.author?.username}: ${clean(tweet.quotedTweet.text)}` : '';
    const title = headline(text);
    const summary = [title === text ? '' : text, quoted].filter(Boolean).join('\n\n');
    const media = tweet.media?.find(item => /^https:\/\//.test(item.url ?? ''));
    return [{
      title, summary, url: `https://x.com/${tweet.author?.username ?? 'i'}/status/${tweet.id}`, guid: `x:${tweet.id}`, stamp,
      link: String(tweet.text ?? '').match(/https:\/\/t\.co\/\w+/)?.[0] ?? '',
      publisher: `@${tweet.author?.username ?? 'unknown'}`, image: media?.url ?? '', x: true,
    }];
  });
}

// A post that links an article is published with that article's URL, so it matches the publisher's own feed entry and is dropped as a copy.
async function articleLink(link) {
  if (!link) return '';
  try {
    const response = await fetch(link, { method: 'HEAD', signal: AbortSignal.timeout(8000) });
    const target = new URL(response.url);
    return /^https:$/.test(target.protocol) && !/(^|\.)(x|twitter)\.com$/i.test(target.hostname) ? target.href : '';
  } catch { return ''; }
}

// Separate publisher groups prevent a prolific account from filling the entire intake.
export async function timeline() {
  const cached = JSON.parse(await readFile(cacheFile, 'utf8').catch(() => '{}'));
  if (cached.sources === sourceVersion && cached.at && Date.now() - Date.parse(cached.at) < interval) return { items: cached.items ?? [], failures: cached.failures ?? [] };
  const env = { ...process.env, ...await login() };
  const settled = await Promise.allSettled(timelineSources.map(async source => {
    const { stdout } = await promisify(execFile)(bird, [...source.args, '--json', '--plain', '--timeout', '20000'], {
      env, timeout: 45000, maxBuffer: 16 * 1024 * 1024,
    });
    return sourceItems(JSON.parse(stdout), source);
  }));
  const failures = settled.flatMap((entry, index) => entry.status === 'rejected' ? [`X source ${timelineSources[index].name}: query failed`] : []);
  if (settled.every(entry => entry.status === 'rejected')) throw new Error('All X source queries failed');
  const known = new Map((cached.items ?? []).map(item => [item.guid, item.url]));
  const posts = new Map(settled.filter(entry => entry.status === 'fulfilled').flatMap(entry => entry.value).map(item => [item.guid, item]));
  const fresh = await Promise.all([...posts.values()].map(async ({ link, ...item }) => {
    const url = known.get(item.guid)?.startsWith('https://x.com/') === false ? known.get(item.guid) : await articleLink(link);
    return linkedArticle(item, url);
  }));
  await mkdir(dirname(cacheFile), { recursive: true, mode: 0o700 });
  await writeFile(cacheFile, `${JSON.stringify({ at: new Date().toISOString(), sources: sourceVersion, items: fresh, failures })}\n`, { mode: 0o600 });
  return { items: fresh, failures };
}
