import { execFile } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { promisify } from 'node:util';

const bird = process.env.BIRD_BIN ?? join(homedir(), '.local', 'bin', 'bird');
const loginFile = process.env.BIRD_ENV ?? join(homedir(), '.config', 'bird', 'x.env');
const cacheFile = join(homedir(), '.config', 'newswire', 'x-timeline.json');
const interval = Number(process.env.X_POLL_MINUTES ?? 5) * 60000;

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

export function items(tweets) {
  return tweets.flatMap(tweet => {
    const text = clean(tweet.text);
    const stamp = Math.min(Date.parse(tweet.createdAt), Date.now());
    if (!tweet.id || tweet.inReplyToStatusId || text.startsWith('RT @') || text.length < 60 || !Number.isFinite(stamp)) return [];
    const quoted = tweet.quotedTweet ? `Quoting @${tweet.quotedTweet.author?.username}: ${clean(tweet.quotedTweet.text)}` : '';
    const title = headline(text);
    const summary = [title === text ? '' : text, quoted].filter(Boolean).join('\n\n');
    const media = tweet.media?.find(item => /^https:\/\//.test(item.url ?? ''));
    return [{
      title, summary, url: `https://x.com/${tweet.author?.username ?? 'i'}/status/${tweet.id}`, guid: `x:${tweet.id}`, stamp,
      publisher: `@${tweet.author?.username ?? 'unknown'}`, image: media?.url ?? '', x: true,
    }];
  });
}

// The Following timeline, fetched at most once per interval; the monitor runs every minute.
export async function timeline() {
  const cached = JSON.parse(await readFile(cacheFile, 'utf8').catch(() => '{}'));
  if (cached.at && Date.now() - Date.parse(cached.at) < interval) return cached.items ?? [];
  const { stdout } = await promisify(execFile)(bird, ['home', '--following', '-n', '40', '--json', '--plain', '--timeout', '20000'], {
    env: { ...process.env, ...await login() }, timeout: 45000, maxBuffer: 16 * 1024 * 1024,
  });
  const parsed = JSON.parse(stdout);
  const fresh = items(Array.isArray(parsed) ? parsed : parsed.tweets ?? []);
  await mkdir(dirname(cacheFile), { recursive: true, mode: 0o700 });
  await writeFile(cacheFile, `${JSON.stringify({ at: new Date().toISOString(), items: fresh })}\n`, { mode: 0o600 });
  return fresh;
}
