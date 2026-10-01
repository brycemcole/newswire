import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { getText } from './fetch.mjs';

const run = promisify(execFile);
const safari = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';

export const walled = url => /(^|\.)bloomberg\.com$/i.test(new URL(url).hostname);

async function search(query) {
  const xml = await getText(`https://news.google.com/rss/search?q=${encodeURIComponent(query)}&hl=en-US&gl=US&ceid=US:en`);
  return [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].map(([, item]) => ({
    source: item.match(/<source url="([^"]+)"/)?.[1] ?? '',
    link: item.match(/<link>([^<]+)/)?.[1] ?? '',
  })).filter(item => item.link && !/bloomberg\.com/.test(item.source));
}

// Bloomberg's site sits behind a PerimeterX bot wall and a paywall, so the app cannot read it. Outlets that
// license the Bloomberg wire (Yahoo Finance, Mint, TradingView and others) republish the full story; link one
// whose page carries the wire's "(Bloomberg) --" dateline, which rules out rewrites that merely cite Bloomberg.
export async function readableCopy(title, url, resolve) {
  const slug = new URL(url).pathname.split('/').pop().replace(/-/g, ' ');
  for (const query of [`"${title}" when:1d`, `${slug} when:1d`]) {
    const candidates = await search(query);
    for (const candidate of candidates.slice(0, 4)) {
      const copy = await resolve(candidate.link);
      if (!/^https:\/\//.test(copy) || walled(copy)) continue;
      // Some publishers' response headers overflow Node's fetch limit; curl reads them fine.
      const html = await run('curl', ['-sL', '--max-time', '12', '-A', safari, copy], { maxBuffer: 32 * 1024 * 1024 }).then(result => result.stdout, () => '');
      if (/\(Bloomberg\)\s*(--|—|–)/.test(html)) return copy;
    }
    if (candidates.length) break;
  }
  return null;
}
