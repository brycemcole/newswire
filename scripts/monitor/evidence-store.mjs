import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { link, mkdir, open, readFile, readdir, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { basename, dirname, join, parse } from 'node:path';
import { createInterface } from 'node:readline';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const digest = value => createHash('sha256').update(value).digest('hex');

export async function withFileLock(file, action, { timeoutMs = 30000 } = {}) {
  const lock = `${file}.lock`;
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const deadline = Date.now() + timeoutMs;
  let handle;
  while (!handle) {
    try { handle = await open(lock, 'wx', 0o600); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        const info = await stat(lock);
        if (Date.now() - info.mtimeMs > 10 * 60 * 1000) { await unlink(lock); continue; }
      } catch (statError) { if (statError.code === 'ENOENT') continue; throw statError; }
      if (Date.now() >= deadline) throw new Error(`Timed out waiting for archive lock: ${lock}`);
      await pause(10 + Math.floor(Math.random() * 20));
    }
  }
  try { return await action(); }
  finally { await handle.close(); await unlink(lock).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
}

const rootFor = file => `${file}.evidence`;
const writeImmutable = async (path, value) => {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
  await writeFile(temporary, JSON.stringify(value) + '\n', { flag: 'wx', mode: 0o600 });
  try { await link(temporary, path); }
  catch (error) { if (error.code !== 'EEXIST') { await unlink(temporary).catch(() => {}); throw error; } }
  await unlink(temporary).catch(() => {});
};
const writeLatest = async (path, value) => {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
  await writeFile(temporary, JSON.stringify(value) + '\n', { flag: 'wx', mode: 0o600 });
  await rename(temporary, path);
};

export async function appendEvidence(file, records) {
  if (!records.length) return;
  const root = rootFor(file);
  await withFileLock(join(root, 'write'), async () => {
    const counterPath = join(root, 'sequence.json');
    let previous = 0n;
    try { previous = BigInt(JSON.parse(await readFile(counterPath, 'utf8')).last); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const clock = BigInt(Date.now()) * 1000000n;
    let sequence = clock > previous ? clock : previous + 1n;
    await writeLatest(counterPath, { last: String(sequence + BigInt(records.length) - 1n) });
    for (const record of records) {
      const key = record.type === 'impact_classification' ? `classification/${record.classifier_version}/${record.id}`
        : record.type === 'impact_delivery' ? `delivery/${record.id}` : 'events';
      const base = `${record.classified_at ?? record.observed_at ?? record.attempted_at ?? record.delivered_at ?? String(Date.now())}-${digest(JSON.stringify(record)).slice(0, 16)}`;
      const recordId = `${base}-${sequence}`;
      const body = join(root, 'records', key, `${digest(recordId)}.json`);
      const ordered = join(root, 'ordered', key, String(sequence).padStart(24, '0'), `${digest(recordId)}.json`);
      await writeImmutable(body, record);
      await mkdir(dirname(ordered), { recursive: true, mode: 0o700 });
      await link(body, ordered).catch(error => { if (error.code !== 'EEXIST') throw error; });
      sequence += 1n;
      if (record.type === 'impact_classification' || record.type === 'impact_delivery') {
        await writeLatest(join(root, 'latest', key + '.json'), { record: basename(body), value: record });
      }
    }
  });
}

export async function appendHeadlineVersions(file, records) {
  if (!records.length) return;
  const root = rootFor(file);
  await withFileLock(join(root, 'write'), async () => {
    for (const record of records) {
      const story = digest(`${record.source}\n${record.guid}`);
      const latestPath = join(root, 'latest', 'headline', `${story}.json`);
      let latest;
      try { latest = JSON.parse(await readFile(latestPath, 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (latest?.content_hash === record.content_hash) continue;
      let first_seen_at = record.first_seen_at;
      if (latest?.record) {
        const previousPath = join(root, 'records', 'headline', story, `${latest.record}.json`);
        const previous = JSON.parse(await readFile(previousPath, 'utf8'));
        first_seen_at = previous.first_seen_at;
      }
      const version = { ...record, first_seen_at };
      const versionPath = join(root, 'records', 'headline', story, `${record.content_hash}.json`);
      await writeImmutable(versionPath, version);
      await writeLatest(latestPath, { content_hash: record.content_hash, record: record.content_hash });
    }
  });
}

export async function readEvidence(file, { type, classifierVersion, ids, history = false } = {}) {
  const root = rootFor(file);
  const result = [];
  if (type === 'headline_version') {
    const directory = join(root, 'records', 'headline');
    for (const story of await readdir(directory).catch(error => error.code === 'ENOENT' ? [] : Promise.reject(error))) {
      const versions = join(directory, story);
      for (const name of (await readdir(versions)).filter(name => name.endsWith('.json')).sort()) result.push(JSON.parse(await readFile(join(versions, name), 'utf8')));
    }
    return result;
  }
  if (type === 'impact_classification') {
    const prefix = join(root, 'latest', 'classification', classifierVersion ?? '');
    if (history) {
      for (const id of ids ?? []) {
        const directory = join(root, 'ordered', 'classification', classifierVersion ?? '', id);
        for (const sequence of (await readdir(directory).catch(error => error.code === 'ENOENT' ? [] : Promise.reject(error))).sort())
          for (const name of (await readdir(join(directory, sequence))).filter(name => name.endsWith('.json')).sort()) result.push(JSON.parse(await readFile(join(directory, sequence, name), 'utf8')));
      }
      return result;
    }
    for (const id of ids ?? []) {
      try { result.push(JSON.parse(await readFile(join(prefix, `${id}.json`), 'utf8')).value); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return result;
  }
  if (type === 'impact_delivery') {
    const directory = join(root, 'latest', 'delivery');
    for (const id of ids ?? []) {
      const name = `${id}.json`;
      try { result.push(JSON.parse(await readFile(join(directory, name), 'utf8')).value); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return result;
  }
  const events = join(root, 'records', 'events');
  for (const name of await readdir(events).catch(error => error.code === 'ENOENT' ? [] : Promise.reject(error))) result.push(JSON.parse(await readFile(join(events, name), 'utf8')));
  return result;
}

export async function migrateLegacyEvidence(file, evidenceFile, toRecord) {
  const marker = `${file}.migration-v1`;
  try { await stat(marker); return false; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  let raw;
  try { raw = JSON.parse(await readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') raw = {}; else throw new Error(`Cannot backfill legacy archive ${file}: ${error.message}`); }
  const records = Object.entries(raw).map(([id, item]) => toRecord(id, item));
  await appendHeadlineVersions(evidenceFile, records);
  const legacyLog = `${evidenceFile}`;
  const logMarker = `${marker}.log`;
  try { await stat(logMarker); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    let logStat;
    try { logStat = await stat(legacyLog); } catch (statError) { if (statError.code !== 'ENOENT') throw statError; }
    if (logStat) {
      const reader = createInterface({ input: createReadStream(legacyLog, { encoding: 'utf8' }), crlfDelay: Infinity });
      let lineNumber = 0, batch = [], headlineBatch = [];
      for await (const line of reader) {
        lineNumber += 1;
        if (!line.trim()) throw new Error(`Corrupt legacy evidence log ${legacyLog} at line ${lineNumber}`);
        let event;
        try { event = JSON.parse(line); } catch { throw new Error(`Corrupt legacy evidence log ${legacyLog} at line ${lineNumber}`); }
        if (event.type === 'headline_version') headlineBatch.push(event); else batch.push(event);
        if (batch.length + headlineBatch.length >= 250) {
          await appendHeadlineVersions(evidenceFile, headlineBatch); await appendEvidence(evidenceFile, batch);
          batch = []; headlineBatch = [];
        }
      }
      await appendHeadlineVersions(evidenceFile, headlineBatch); await appendEvidence(evidenceFile, batch);
    }
    await writeFile(logMarker, JSON.stringify({ source_bytes: logStat?.size ?? 0, migrated_at: new Date().toISOString() }) + '\n', { flag: 'wx', mode: 0o600 });
  }
  const temporary = `${marker}.${process.pid}.tmp`;
  await writeFile(temporary, JSON.stringify({ migrated_at: new Date().toISOString(), count: records.length, source_bytes: (await stat(file).catch(() => ({ size: 0 }))).size }) + '\n', { flag: 'wx', mode: 0o600 });
  await rename(temporary, marker);
  return true;
}
