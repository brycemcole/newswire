import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { canonicalUrl } from './headline-dedupe.mjs';
import { appendHeadlineVersions, migrateLegacyEvidence, withFileLock } from './evidence-store.mjs';

const normalizedText = value => typeof value === 'string' ? value.normalize('NFKC').replace(/\s+/gu, ' ').trim() : '';
const headlineContentHash = item => createHash('sha256').update(JSON.stringify({
  title: normalizedText(item.title),
  summary: normalizedText(item.summary),
  body: normalizedText(item.body ?? item.content),
  url: canonicalUrl(item.url),
  publisher: normalizedText(item.publisher),
  publishedAt: Number.isFinite(item.stamp) ? new Date(item.stamp).toISOString() : null,
})).digest('hex');

export async function archiveHeadlines(items, { now = Date.now(), file = join(homedir(), '.config', 'newswire', 'raw-headlines.json'), evidenceFile = `${file}.evidence.jsonl` } = {}) {
  const cutoff = now - 7 * 86400000;
  const incoming = items.filter(item => !Number.isFinite(item.stamp) || item.stamp <= now);
  const observedAt = new Date(now).toISOString();
  const evidence = incoming.map(item => {
    const canonical_url = canonicalUrl(item.url);
    const content = { ...item, canonical_url };
    const content_hash = headlineContentHash(item);
    return { type: 'headline_version', observed_at: observedAt, first_seen_at: observedAt, published_at: Number.isFinite(item.stamp) ? new Date(item.stamp).toISOString() : null,
      publication_time_status: Number.isFinite(item.stamp) ? 'known' : 'unknown', content_hash, canonical_url, source: item.publisher ?? '', guid: item.guid ?? '', provenance: item.provenance ?? { via: item.via ?? [], publisher: item.publisher ?? '' }, content };
  });
  return withFileLock(file, async () => {
    await migrateLegacyEvidence(file, evidenceFile, (id, item) => {
      const canonical_url = canonicalUrl(item.url);
      const content = { ...item, canonical_url };
      const content_hash = headlineContentHash(item);
      const first_seen_at = item.first_seen_at ?? null;
      return { type: 'headline_version', observed_at: first_seen_at ?? observedAt, first_seen_at, published_at: Number.isFinite(item.stamp) ? new Date(item.stamp).toISOString() : null,
        publication_time_status: Number.isFinite(item.stamp) ? 'known' : 'unknown', content_hash, canonical_url, source: item.publisher ?? '', guid: item.guid ?? id,
        provenance: item.provenance ?? { via: item.via ?? [], publisher: item.publisher ?? '' }, content };
    });
    const records = {};
    let previous = {};
    try { previous = JSON.parse(await readFile(file, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    for (const [id, item] of Object.entries(previous)) {
      if (item.stamp >= now - 7 * 86400000) records[id] = item;
    }
    const byOriginal = new Map(Object.entries(records).map(([key, item]) => [`${item.publisher}\n${item.guid}`, key]));
    for (const item of incoming) {
      if (!Number.isFinite(item.stamp) || item.stamp < cutoff) continue;
      const contentHash = headlineContentHash(item);
      const originalId = createHash('sha256').update(`${item.publisher}\n${item.guid}`).digest('hex');
      const previousId = byOriginal.get(`${item.publisher}\n${item.guid}`);
      const previousItem = previousId && records[previousId];
      const previousHash = previousItem && headlineContentHash(previousItem);
      const key = !previousItem || previousHash === contentHash ? (previousId ?? originalId) : createHash('sha256').update(`${item.publisher}\n${item.guid}\n${contentHash}`).digest('hex');
      records[key] ??= { ...item, first_seen_at: observedAt };
      byOriginal.set(`${item.publisher}\n${item.guid}`, key);
    }
    const kept = Object.fromEntries(Object.entries(records).sort((a, b) => b[1].stamp - a[1].stamp));
    await appendHeadlineVersions(evidenceFile, evidence);
    await mkdir(dirname(file), { recursive: true, mode: 0o700 });
    const temporary = `${file}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
    await writeFile(temporary, JSON.stringify(kept) + '\n', { mode: 0o600 });
    await rename(temporary, file);
    return { records: Object.values(kept) };
  });
}
