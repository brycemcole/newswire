import { load } from '../state.mjs';

export const id = 'digest';

const hour = 14;
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';

export function summarize(entries, now = Date.now()) {
  const cutoff = now - 86400000;
  const counts = new Map();
  let latest = null;
  for (const entry of Object.values(entries ?? {})) {
    if (entry?.rule === 'digest') continue;
    const at = Date.parse(entry?.at ?? '');
    if (!Number.isFinite(at) || at < cutoff || at > now + 60000) continue;
    counts.set(entry.rule, (counts.get(entry.rule) ?? 0) + 1);
    if (!latest || at > latest.at) latest = { at, rule: entry.rule };
  }
  return {
    total: [...counts.values()].reduce((sum, count) => sum + count, 0),
    counts: [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])),
    latest: latest?.rule ?? null,
  };
}

export async function run() {
  const now = new Date();
  if (now.getUTCHours() < hour) return { events: [], failures: [] };
  const { total, counts, latest } = summarize(await load(), now.getTime());
  if (!total) return { events: [], failures: [] };
  const day = now.toISOString().slice(0, 10);
  const breakdown = counts.map(([rule, count]) => `${rule} ${count}`).join(', ');
  return {
    events: [{
      key: `digest:${day}`,
      title: `Wire digest: ${total} alert${total === 1 ? '' : 's'} on the wire in the past 24 hours`,
      summary: `Between ${new Date(now.getTime() - 86400000).toISOString().slice(0, 16).replace('T', ' ')}Z and ${now.toISOString().slice(0, 16).replace('T', ' ')}Z the deterministic monitor published ${total} alert${total === 1 ? '' : 's'}: ${breakdown}.${latest ? ` The most recent alert came from ${latest}.` : ''} Counts cover published events, including continuous rules repeating after their cooldowns.`,
      source: 'Newswire Monitor',
      url: `${origin}/?digest=${day}`,
      published_at: now.toISOString(),
      category: 'general',
      priority: 'normal',
      tickers: [],
      tags: ['deterministic', 'digest'],
    }],
    failures: [],
  };
}
