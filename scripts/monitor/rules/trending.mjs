import { getJson } from '../fetch.mjs';

export const id = 'trending';

async function hackerNews(events, failures) {
  try {
    const ids = (await getJson('https://hacker-news.firebaseio.com/v0/topstories.json')).slice(0, 20);
    const items = await Promise.all(ids.map(id => getJson(`https://hacker-news.firebaseio.com/v0/item/${id}.json`).catch(() => null)));
    for (const item of items) {
      if (!item?.url || !item.title || (item.score ?? 0) < 600) continue;
      const age = Date.now() - item.time * 1000;
      if (age > 36 * 3600000) continue;
      events.push({
        key: `trending:hn:${item.id}`,
        title: item.title.slice(0, 300),
        summary: `This link reached ${item.score} points and ${item.descendants ?? 0} comments on Hacker News, placing it among the platform's most discussed items of the day. Ranking signal only; the score does not verify the linked claim.`,
        source: 'Hacker News',
        url: item.url,
        published_at: new Date(item.time * 1000).toISOString(),
        category: 'technology',
        priority: 'normal',
        tickers: [],
        tags: ['deterministic', 'trending', 'hacker-news'],
      });
    }
  } catch (error) {
    failures.push(`hacker-news: ${error.message}`);
  }
}

export async function run() {
  const events = [];
  const failures = [];
  await hackerNews(events, failures);
  return { events, failures };
}
