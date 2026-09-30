import { AttestError, checkChallenge, fromBase64, makeChallenge, sha256, toBase64, verifyAssertion, verifyAttestation } from './attest';
import { quotes, resolve, type Mention } from './quotes';

interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  WRITER_TOKEN?: string;
  ATTEST_APP_ID?: string;
  ATTEST_ROOT_CA?: string;
  BRAIN?: D1Database;
  AI?: { run(model: string, input: unknown): Promise<Record<string, unknown>> };
  BRAIN_AI_MODEL?: string;
}

const categories = ['general', 'markets', 'technology', 'economy', 'politics', 'world', 'science'];
const priorities = ['normal', 'urgent', 'breaking'];
const fields = ['external_id', 'title', 'summary', 'body', 'source', 'url', 'published_at', 'category', 'priority', 'tickers', 'tags', 'agent', 'image_url'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const encoder = new TextEncoder();
const bodyLimit = 131072;

class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}

function invalid(message: string): never { throw new ApiError(400, 'invalid_request', message); }
function json(value: unknown, status = 200) { return Response.json(value, { status }); }
function text(value: unknown, name: string, max: number, fallback?: string): string {
  if (value === undefined && fallback !== undefined) return fallback;
  if (typeof value !== 'string' || value.length > max || (fallback === undefined && !value.trim()) || value.includes('\0')) invalid(`Invalid ${name}`);
  return value.trim();
}
function choice(value: unknown, name: string, values: string[], fallback?: string) {
  const result = text(value, name, 40, fallback);
  if (!values.includes(result)) invalid(`Invalid ${name}`);
  return result;
}
function timestamp(value: unknown): string {
  if (typeof value !== 'string') invalid('Invalid published_at');
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(Z|[+-](\d{2}):(\d{2}))$/.exec(value);
  if (!match) invalid('Invalid published_at');
  const [, y, m, d, h, min, s, , oh, om] = match;
  const days = new Date(Date.UTC(Number(y), Number(m), 0)).getUTCDate();
  if (+m < 1 || +m > 12 || +d < 1 || +d > days || +h > 23 || +min > 59 || +s > 59 || +(oh ?? 0) > 23 || +(om ?? 0) > 59) invalid('Invalid published_at');
  const ms = Date.parse(value);
  if (!Number.isFinite(ms) || ms > Date.now() + 300000) invalid('Invalid published_at');
  return new Date(ms).toISOString();
}
function array(value: unknown, name: string, max: number): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 20) invalid(`Invalid ${name}`);
  return value.map(item => text(item, name, max));
}
function input(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid('Expected a story object');
  const data = value as Record<string, unknown>;
  if (Object.keys(data).some(key => !fields.includes(key))) invalid('Unknown story field');
  let url: URL;
  try { url = new URL(text(data.url, 'url', 4096)); } catch { return invalid('Invalid url'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) invalid('Invalid url');
  url.hash = '';
  if (encoder.encode(url.href).length > 4096) invalid('Invalid url');
  let image = '';
  if (data.image_url !== undefined && data.image_url !== '') {
    try { image = new URL(text(data.image_url, 'image_url', 2048)).href; } catch { return invalid('Invalid image_url'); }
    if (!image.startsWith('https://')) invalid('Invalid image_url');
  }
  return {
    external_id: text(data.external_id, 'external_id', 200), title: text(data.title, 'title', 300),
    summary: text(data.summary, 'summary', 2000, ''), body: text(data.body, 'body', 20000, ''),
    source: text(data.source, 'source', 100), url: url.href, published_at: timestamp(data.published_at),
    category: choice(data.category, 'category', categories, 'general'), priority: choice(data.priority, 'priority', priorities, 'normal'),
    tickers: array(data.tickers, 'tickers', 20), tags: array(data.tags, 'tags', 40), agent: text(data.agent, 'agent', 100, 'unknown'), image_url: image,
  };
}
function query(params: URLSearchParams, allowed: string[]) {
  const result: Record<string, string> = Object.create(null);
  for (const [key, value] of params) {
    if (!allowed.includes(key) || Object.hasOwn(result, key)) invalid('Unknown or repeated query parameter');
    result[key] = value;
  }
  return result;
}
const sessionTTL = 7 * 86400000;
const hex = (bytes: Uint8Array) => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
async function authenticate(request: Request, env: Env, write: boolean) {
  if (!env.WRITER_TOKEN?.trim()) throw new ApiError(503, 'unavailable', 'Authentication is not configured');
  const token = /^Bearer ([^\s]+)$/i.exec(request.headers.get('Authorization') ?? '')?.[1];
  if (!token || token.length > 4096) throw new ApiError(401, 'unauthorized', 'Bearer token required');
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(s)));
  const [actual, writer] = await Promise.all([digest(token), digest(env.WRITER_TOKEN)]);
  if (actual.reduce((diff, byte, i) => diff | (byte ^ writer[i]), 0) === 0) return;
  const session = await env.DB.prepare('SELECT 1 FROM sessions WHERE token_hash = ? AND expires_at > ?').bind(hex(actual), Date.now()).first();
  if (!session) throw new ApiError(401, 'unauthorized', 'Invalid bearer token');
  if (write) throw new ApiError(403, 'forbidden', 'Writer token required');
}
async function mintSession(env: Env, keyId: string) {
  const token = hex(crypto.getRandomValues(new Uint8Array(32)));
  const expires = Date.now() + sessionTTL;
  await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE expires_at < ?').bind(Date.now()),
    env.DB.prepare('INSERT INTO sessions (token_hash, key_id, expires_at) VALUES (?, ?, ?)').bind(hex(await sha256(encoder.encode(token))), keyId, expires),
  ]);
  return json({ token, expires_at: new Date(expires).toISOString() }, 201);
}
async function attestRoute(request: Request, path: string, env: Env) {
  if (!env.WRITER_TOKEN?.trim()) throw new ApiError(503, 'unavailable', 'Authentication is not configured');
  if (path === '/v1/attest/challenge') {
    if (request.method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
    return json({ challenge: await makeChallenge(env.WRITER_TOKEN) });
  }
  if (request.method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
  const data = await readBody(request) as Record<string, unknown> | null;
  const keyId = text(data?.key_id, 'key_id', 100);
  let keyBytes: Uint8Array;
  try { keyBytes = fromBase64(keyId, 100); } catch { return invalid('Invalid key_id'); }
  const challenge = text(data?.challenge, 'challenge', 200);
  if (!await checkChallenge(env.WRITER_TOKEN, challenge)) throw new ApiError(401, 'stale_challenge', 'Challenge expired');
  const appId = env.ATTEST_APP_ID ?? 'A792L5W262.com.brycecole.newswire';
  const now = new Date().toISOString();
  try {
    if (path === '/v1/attest') {
      const publicKey = await verifyAttestation(fromBase64(data?.attestation, 20000), challenge, keyBytes, appId, env.ATTEST_ROOT_CA);
      await env.DB.prepare('INSERT INTO attested_devices (key_id, public_key, counter, created_at, last_seen_at) VALUES (?, ?, 0, ?, ?) ON CONFLICT(key_id) DO UPDATE SET public_key = excluded.public_key, counter = 0, last_seen_at = excluded.last_seen_at').bind(keyId, toBase64(publicKey), now, now).run();
      return mintSession(env, keyId);
    }
    const device = await env.DB.prepare('SELECT public_key, counter FROM attested_devices WHERE key_id = ?').bind(keyId).first<{ public_key: string; counter: number }>();
    if (!device) throw new ApiError(404, 'unknown_key', 'Key is not enrolled');
    const counter = await verifyAssertion(fromBase64(data?.assertion, 4000), challenge, fromBase64(device.public_key), appId, device.counter);
    const updated = await env.DB.prepare('UPDATE attested_devices SET counter = ?, last_seen_at = ? WHERE key_id = ? AND counter = ?').bind(counter, now, keyId, device.counter).run();
    if (!updated.meta.changes) throw new ApiError(409, 'conflict', 'Assertion raced, retry');
    return mintSession(env, keyId);
  } catch (error) {
    if (error instanceof AttestError) throw new ApiError(401, 'attestation_failed', error.message);
    throw error;
  }
}
function story(row: Record<string, unknown>) { return { ...row, tickers: JSON.parse(row.tickers as string), tags: JSON.parse(row.tags as string) }; }
async function readBody(request: Request): Promise<unknown> {
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') invalid('Content-Type must be application/json');
  if (Number(request.headers.get('content-length')) > bodyLimit) throw new ApiError(413, 'too_large', 'Body exceeds 128 KiB');
  const reader = request.body?.getReader();
  if (!reader) invalid('Missing body');
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > bodyLimit) { await reader.cancel(); throw new ApiError(413, 'too_large', 'Body exceeds 128 KiB'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes)); } catch { return invalid('Invalid JSON'); }
}
async function ingest(value: unknown, env: Env, ctx?: ExecutionContext) {
  const data = input(value);
  const id = crypto.randomUUID();
  const values = { id, ...data, received_at: new Date().toISOString(), tickers: JSON.stringify(data.tickers), tags: JSON.stringify(data.tags) };
  const columns = Object.keys(values);
  const results = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare(`INSERT INTO stories (${columns.join(',')}) VALUES (${columns.map(() => '?').join(',')}) ON CONFLICT DO NOTHING`).bind(...Object.values(values)),
    env.DB.prepare('SELECT * FROM stories WHERE external_id = ? OR url = ? ORDER BY CASE WHEN external_id = ? THEN 0 ELSE 1 END LIMIT 1').bind(data.external_id, data.url, data.external_id),
  ]);
  const row = results[1].results[0];
  if (!row) throw new Error('Missing inserted story');
  const duplicate = row.id !== id;
  if (!duplicate && !data.tickers.length) ctx?.waitUntil(tag(id, `${data.title}\n${data.summary}`, env).catch(() => undefined));
  return json({ story: story(row), duplicate }, duplicate ? 200 : 201);
}
async function tag(id: string, content: string, env: Env) {
  const mentions = await resolve(content);
  if (mentions.length) await env.DB.prepare("UPDATE stories SET tickers = ? WHERE id = ? AND tickers = '[]'").bind(JSON.stringify(mentions.map(item => item.symbol)), id).run();
}
async function quoteRoute(url: URL) {
  const q = query(url.searchParams, ['symbols', 'text']);
  const mentions: Mention[] = [];
  if (q.symbols !== undefined) {
    const symbols = text(q.symbols, 'symbols', 200).split(',').map(item => item.trim()).filter(Boolean);
    if (symbols.length > 12 || symbols.some(item => !/^[A-Za-z0-9^=.\-]{1,20}$/.test(item))) invalid('Invalid symbols');
    mentions.push(...symbols.map(symbol => ({ symbol: symbol.toUpperCase(), match: symbol.toUpperCase() })));
  }
  if (q.text !== undefined) {
    for (const mention of await resolve(text(q.text, 'text', 3000))) if (!mentions.some(item => item.symbol === mention.symbol)) mentions.push(mention);
  }
  if (!mentions.length && q.symbols === undefined && q.text === undefined) invalid('Provide symbols or text');
  return json({ quotes: await quotes(mentions.slice(0, 12)) });
}
async function list(url: URL, env: Env) {
  const q = query(url.searchParams, ['limit', 'cursor', 'category', 'priority', 'ticker', 'tag', 'agent', 'source', 'since', 'until', 'retracted', 'q']);
  if (q.limit !== undefined && !/^(?:[1-9]\d?|100)$/.test(q.limit)) invalid('Invalid limit');
  const limit = Number(q.limit ?? 50);
  const where: string[] = [];
  const args: (string | number)[] = [];
  for (const [name, options] of [['category', categories], ['priority', priorities]] as const) {
    if (q[name] !== undefined) { where.push(`${name} = ?`); args.push(choice(q[name], name, options)); }
  }
  const retraction = q.retracted === undefined ? 'exclude' : choice(q.retracted, 'retracted', ['exclude', 'include', 'only']);
  if (retraction !== 'include') where.push(retraction === 'only' ? 'retracted_at IS NOT NULL' : 'retracted_at IS NULL');
  if (q.ticker !== undefined) { where.push('EXISTS (SELECT 1 FROM json_each(stories.tickers) WHERE value = ?)'); args.push(text(q.ticker, 'ticker', 20)); }
  if (q.tag !== undefined) { where.push('EXISTS (SELECT 1 FROM json_each(stories.tags) WHERE value = ?)'); args.push(text(q.tag, 'tag', 40)); }
  if (q.agent !== undefined) { where.push('agent = ?'); args.push(text(q.agent, 'agent', 100)); }
  if (q.source !== undefined) { where.push('source = ?'); args.push(text(q.source, 'source', 100)); }
  if (q.since !== undefined) { where.push('published_at >= ?'); args.push(timestamp(q.since)); }
  if (q.until !== undefined) { where.push('published_at <= ?'); args.push(timestamp(q.until)); }
  if (q.q !== undefined) {
    const term = text(q.q, 'q', 200).replace(/[\\%_]/g, '\\$&');
    where.push("(title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR source LIKE ? ESCAPE '\\' OR agent LIKE ? ESCAPE '\\')");
    args.push(`%${term}%`, `%${term}%`, `%${term}%`, `%${term}%`, `%${term}%`);
  }
  if (q.cursor !== undefined) {
    try {
      if (q.cursor.length > 256 || !/^[A-Za-z0-9_-]+$/.test(q.cursor)) invalid('Invalid cursor');
      const cursor = JSON.parse(atob(q.cursor.replace(/-/g, '+').replace(/_/g, '/')));
      if (!Array.isArray(cursor) || cursor.length !== 2 || typeof cursor[1] !== 'string' || !uuid.test(cursor[1]) || timestamp(cursor[0]) !== cursor[0]) invalid('Invalid cursor');
      where.push('(published_at < ? OR (published_at = ? AND id < ?))'); args.push(cursor[0], cursor[0], cursor[1]);
    } catch { invalid('Invalid cursor'); }
  }
  const { results } = await env.DB.prepare(`SELECT * FROM stories ${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY published_at DESC, id DESC LIMIT ?`).bind(...args, limit + 1).all();
  const rows = results.slice(0, limit);
  const last = rows.at(-1);
  const cursor = results.length > limit && last ? btoa(JSON.stringify([last.published_at, last.id])).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') : null;
  return json({ stories: rows.map(story), next_cursor: cursor });
}
const brainMap: Record<string, string> = {
  ai: 'technology', tech: 'technology', technology: 'technology', security: 'technology', 'web dev': 'technology', 'hacker news': 'technology', lobsters: 'technology', 'dev community': 'technology',
  papers: 'science', research: 'science', biotech: 'science', science: 'science', macro: 'economy', economy: 'economy', markets: 'markets', crypto: 'markets', business: 'markets',
  policy: 'politics', politics: 'politics', world: 'world',
};
const brainCategory = `CASE lower(p.category) ${Object.entries(brainMap).map(([key, value]) => `WHEN '${key}' THEN '${value}'`).join(' ')} ELSE 'general' END`;
const brainPriority = "CASE WHEN p.priority >= 10 THEN 'breaking' WHEN p.priority >= 8 THEN 'urgent' ELSE 'normal' END";
const brainSelect = `SELECT p.*, ${brainCategory} AS wire_category, ${brainPriority} AS wire_priority, (SELECT type FROM interactions WHERE post_id = p.id ORDER BY created_at DESC LIMIT 1) AS interaction FROM posts p`;
const brainId = /^[0-9a-f]{32}$/;
const brainFields = ['content', 'title', 'summary', 'body', 'source', 'source_url', 'source_type', 'category', 'priority', 'created_at', 'image_url'];
function brainDB(env: Env) {
  if (!env.BRAIN) throw new ApiError(503, 'unavailable', 'Brain is not configured');
  return env.BRAIN;
}
function brainTime(value: unknown) { return timestamp(value).replace(/\.\d{3}Z$/, 'Z'); }
function headline(content: string) {
  const plain = content.replace(/\s+/g, ' ').trim();
  const title = /^(.{20,160}?)(?:[.!?](?=\s|$)|\s[—–]\s|\s--\s|:\s)/.exec(plain)?.[1] ?? plain;
  return title.length > 160 ? title.slice(0, 157).replace(/\s+\S*$/, '') + '…' : title;
}
function brainStory(row: Record<string, unknown>) {
  const content = String(row.content ?? '');
  const url = String(row.source_url);
  const published = new Date(String(row.created_at)).toISOString();
  let host = '';
  try { host = new URL(url).hostname.replace(/^www\./, ''); } catch { host = ''; }
  return {
    id: row.id, external_id: `brain:${row.id}`, title: (row.title as string) || headline(content), summary: (row.summary as string) || content, body: (row.body as string) || '',
    source: (row.source as string) || host || 'Brain', url, published_at: published, received_at: published, category: row.wire_category, priority: row.wire_priority,
    tickers: [], tags: [String(row.category ?? 'general').toLowerCase(), String(row.source_type)], agent: 'brain', image_url: (row.image_url as string) || '', retracted_at: null,
    interaction: row.interaction ?? null,
  };
}
async function brainList(url: URL, env: Env) {
  const db = brainDB(env);
  const q = query(url.searchParams, ['limit', 'cursor', 'category', 'priority', 'tag', 'source', 'since', 'until', 'q']);
  if (q.limit !== undefined && !/^(?:[1-9]\d?|100)$/.test(q.limit)) invalid('Invalid limit');
  const limit = Number(q.limit ?? 50);
  const where = ["p.source_url LIKE 'http%'"];
  const args: (string | number)[] = [];
  if (q.category !== undefined) { where.push(`${brainCategory} = ?`); args.push(choice(q.category, 'category', categories)); }
  if (q.priority !== undefined) { where.push(`${brainPriority} = ?`); args.push(choice(q.priority, 'priority', priorities)); }
  if (q.tag !== undefined) { const tag = text(q.tag, 'tag', 40).toLowerCase(); where.push('(lower(p.category) = ? OR p.source_type = ?)'); args.push(tag, tag); }
  if (q.source !== undefined) {
    const source = text(q.source, 'source', 100);
    const host = source.replace(/[\\%_]/g, '\\$&');
    where.push("(p.source = ? OR p.source_url LIKE ? ESCAPE '\\' OR p.source_url LIKE ? ESCAPE '\\')");
    args.push(source, `https://${host}/%`, `https://www.${host}/%`);
  }
  if (q.since !== undefined) { where.push('p.created_at >= ?'); args.push(brainTime(q.since)); }
  if (q.until !== undefined) { where.push('p.created_at <= ?'); args.push(brainTime(q.until)); }
  if (q.q !== undefined) {
    const term = `%${text(q.q, 'q', 200).replace(/[\\%_]/g, '\\$&')}%`;
    where.push("(p.content LIKE ? ESCAPE '\\' OR p.title LIKE ? ESCAPE '\\' OR p.summary LIKE ? ESCAPE '\\' OR p.source LIKE ? ESCAPE '\\')");
    args.push(term, term, term, term);
  }
  if (q.cursor !== undefined) {
    try {
      if (q.cursor.length > 256 || !/^[A-Za-z0-9_-]+$/.test(q.cursor)) invalid('Invalid cursor');
      const cursor = JSON.parse(atob(q.cursor.replace(/-/g, '+').replace(/_/g, '/')));
      if (!Array.isArray(cursor) || cursor.length !== 2 || typeof cursor[0] !== 'string' || cursor[0].length > 40 || !Number.isFinite(Date.parse(cursor[0])) || typeof cursor[1] !== 'string' || !brainId.test(cursor[1])) invalid('Invalid cursor');
      where.push('(p.created_at < ? OR (p.created_at = ? AND p.id < ?))'); args.push(cursor[0], cursor[0], cursor[1]);
    } catch { invalid('Invalid cursor'); }
  }
  const { results } = await db.prepare(`${brainSelect} WHERE ${where.join(' AND ')} ORDER BY p.created_at DESC, p.id DESC LIMIT ?`).bind(...args, limit + 1).all();
  const rows = results.slice(0, limit);
  const last = rows.at(-1);
  const cursor = results.length > limit && last ? btoa(JSON.stringify([last.created_at, last.id])).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') : null;
  return json({ stories: rows.map(brainStory), next_cursor: cursor });
}
async function brainIngest(value: unknown, env: Env) {
  const db = brainDB(env);
  const items = (value as { posts?: unknown } | null)?.posts;
  if (!Array.isArray(items) || !items.length || items.length > 50) invalid('Expected 1-50 posts');
  const rows = items.map(item => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) invalid('Expected post objects');
    const data = item as Record<string, unknown>;
    if (Object.keys(data).some(key => !brainFields.includes(key))) invalid('Unknown post field');
    let url: URL;
    try { url = new URL(text(data.source_url, 'source_url', 2048)); } catch { return invalid('Invalid source_url'); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) invalid('Invalid source_url');
    url.hash = '';
    let image = '';
    if (data.image_url !== undefined && data.image_url !== '') {
      try { image = new URL(text(data.image_url, 'image_url', 2048)).href; } catch { return invalid('Invalid image_url'); }
      if (!image.startsWith('https://')) invalid('Invalid image_url');
    }
    const priority = data.priority ?? 5;
    if (!Number.isInteger(priority) || (priority as number) < 1 || (priority as number) > 10) invalid('Invalid priority');
    return {
      content: text(data.content, 'content', 2000), title: text(data.title, 'title', 300, ''), summary: text(data.summary, 'summary', 2000, ''), body: text(data.body, 'body', 20000, ''),
      source: text(data.source, 'source', 100, ''), source_url: url.href, source_type: choice(data.source_type, 'source_type', ['news', 'paper', 'tech', 'custom'], 'tech'),
      category: text(data.category, 'category', 40, 'General'), priority: priority as number, created_at: data.created_at === undefined ? brainTime(new Date().toISOString()) : brainTime(data.created_at), image_url: image,
    };
  });
  const results = await db.batch(rows.map(row => db.prepare(
    'INSERT INTO posts (content, title, summary, body, source, source_url, source_type, category, priority, created_at, image_url) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM posts WHERE source_url = ?)',
  ).bind(row.content, row.title || null, row.summary || null, row.body || null, row.source || null, row.source_url, row.source_type, row.category, row.priority, row.created_at, row.image_url || null, row.source_url)));
  const inserted = results.reduce((total, result) => total + (result.meta.changes ?? 0), 0);
  return json({ inserted, duplicates: rows.length - inserted }, inserted ? 201 : 200);
}
async function brainTaste(env: Env) {
  const db = brainDB(env);
  const since = brainTime(new Date(Date.now() - 48 * 3600000).toISOString());
  const [signals, recent] = await db.batch<Record<string, unknown>>([
    db.prepare("SELECT i.type, p.category, p.source_type, COALESCE(p.title, '') AS title, substr(p.content, 1, 300) AS content FROM interactions i JOIN posts p ON p.id = i.post_id ORDER BY i.created_at DESC LIMIT 80"),
    db.prepare('SELECT COALESCE(title, substr(content, 1, 160)) AS title FROM posts WHERE created_at >= ? ORDER BY created_at DESC LIMIT 150').bind(since),
  ]);
  return json({ signals: signals.results, recent: recent.results.map(row => row.title) });
}
async function brainAI(value: unknown, env: Env) {
  if (!env.AI) throw new ApiError(503, 'unavailable', 'AI is not configured');
  const data = value as Record<string, unknown> | null;
  const messages = data?.messages;
  if (!Array.isArray(messages) || !messages.length || messages.length > 8) invalid('Expected 1-8 messages');
  const clean = messages.map(message => {
    const item = message as Record<string, unknown> | null;
    return { role: choice(item?.role, 'role', ['system', 'user', 'assistant']), content: text(item?.content, 'content', 60000) };
  });
  const maxTokens = data?.max_tokens ?? 1024;
  if (!Number.isInteger(maxTokens) || (maxTokens as number) < 1 || (maxTokens as number) > 4096) invalid('Invalid max_tokens');
  const model = data?.model === undefined ? env.BRAIN_AI_MODEL || '@cf/meta/llama-3.3-70b-instruct-fp8-fast' : text(data.model, 'model', 100);
  if (!/^@cf\/[\w.-]+\/[\w.-]+$/.test(model)) invalid('Invalid model');
  let result: Record<string, unknown>;
  try { result = await env.AI.run(model, { messages: clean, max_tokens: maxTokens, temperature: 0.2 }); } catch (error) {
    throw new ApiError(502, 'ai_failed', error instanceof Error ? error.message.slice(0, 200) : 'AI request failed');
  }
  const choices = result?.choices as { message?: { content?: unknown } }[] | undefined;
  const output = result?.output as { type?: string; content?: { text?: unknown }[] }[] | undefined;
  const response = result?.response ?? choices?.[0]?.message?.content ?? output?.filter(item => item.type === 'message').flatMap(item => item.content ?? []).map(part => part.text).join('');
  return json({ text: typeof response === 'string' ? response : JSON.stringify(response ?? ''), model, usage: result?.usage ?? null });
}
async function brainRoute(request: Request, url: URL, path: string, env: Env) {
  if (path === '/v1/brain/stories' && request.method === 'GET') return brainList(url, env);
  if (path === '/v1/brain/taste' && request.method === 'GET') { query(url.searchParams, []); return brainTaste(env); }
  if (request.method === 'POST' && ['/v1/brain/posts', '/v1/brain/known', '/v1/brain/ai'].includes(path)) {
    query(url.searchParams, []);
    const body = await readBody(request);
    if (path === '/v1/brain/posts') return brainIngest(body, env);
    if (path === '/v1/brain/ai') return brainAI(body, env);
    const urls = (body as { urls?: unknown } | null)?.urls;
    if (!Array.isArray(urls) || urls.length > 200 || urls.some(item => typeof item !== 'string' || item.length > 2048)) invalid('Expected up to 200 urls');
    const { results } = await brainDB(env).prepare('SELECT source_url FROM posts WHERE source_url IN (SELECT value FROM json_each(?))').bind(JSON.stringify(urls)).all();
    return json({ known: results.map(row => row.source_url) });
  }
  const item = /^\/v1\/brain\/stories\/([0-9a-f]{32})(?:\/(interaction|view))?$/.exec(path);
  if (!item) throw new ApiError(404, 'not_found', 'Route not found');
  query(url.searchParams, []);
  const db = brainDB(env);
  const load = async () => {
    const row = await db.prepare(`${brainSelect} WHERE p.id = ?`).bind(item[1]).first<Record<string, unknown>>();
    if (!row || !String(row.source_url ?? '').startsWith('http')) throw new ApiError(404, 'not_found', 'Story not found');
    return row;
  };
  if (!item[2] && request.method === 'GET') return json({ story: brainStory(await load()) });
  if (request.method !== 'POST' || !item[2]) throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
  await load();
  if (item[2] === 'view') {
    await db.prepare('UPDATE posts SET viewed_at = COALESCE(viewed_at, ?) WHERE id = ?').bind(brainTime(new Date().toISOString()), item[1]).run();
    return json({ viewed: true });
  }
  const type = choice((await readBody(request) as Record<string, unknown> | null)?.type, 'type', ['like', 'dislike', 'save', 'none']);
  await db.batch([
    db.prepare('DELETE FROM interactions WHERE post_id = ?').bind(item[1]),
    ...(type === 'none' ? [] : [db.prepare('INSERT INTO interactions (post_id, type) VALUES (?, ?)').bind(item[1], type)]),
  ]);
  return json({ story: brainStory(await load()) });
}
async function route(request: Request, env: Env, ctx?: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  if (encoder.encode(request.url).length > 8000) throw new ApiError(413, 'too_large', 'URL exceeds 8000 bytes');
  const path = url.pathname;
  const api = path === '/v1' || path.startsWith('/v1/');
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: { Allow: 'GET, POST, DELETE, OPTIONS' } });
  if (path === '/health') {
    if (request.method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
    return json({ ok: true, version: 1 });
  }
  if (path === '/.well-known/apple-app-site-association') {
    return new Response(JSON.stringify({ applinks: { details: [{ appIDs: ['A792L5W262.com.brycecole.newswire'], components: [{ '/': '/plaid/*' }] }] } }), { headers: { 'Content-Type': 'application/json' } });
  }
  if (path === '/plaid/oauth') {
    return new Response('<!doctype html><meta name="viewport" content="width=device-width"><title>Newswire</title><p style="font:17px -apple-system;margin:40px 20px">Return to Newswire to finish connecting your account.</p>', { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
  }
  if (!api) return env.ASSETS.fetch(request);
  if (path === '/v1/attest' || path.startsWith('/v1/attest/')) {
    if (path !== '/v1/attest' && path !== '/v1/attest/challenge' && path !== '/v1/attest/session') throw new ApiError(404, 'not_found', 'Route not found');
    return attestRoute(request, path, env);
  }
  const write = path === '/v1/ingest' || (path === '/v1/stories' && request.method === 'POST') || (/^\/v1\/stories\/([^/]+)$/.test(path) && request.method === 'DELETE')
    || (path === '/v1/devices' && request.method === 'GET') || (/^\/v1\/devices\/([^/]+)$/.test(path) && request.method === 'DELETE')
    || ['/v1/brain/posts', '/v1/brain/known', '/v1/brain/ai', '/v1/brain/taste'].includes(path);
  await authenticate(request, env, write);
  if (path.startsWith('/v1/brain/')) return brainRoute(request, url, path, env);
  if (path === '/v1/devices') {
    query(url.searchParams, []);
    if (request.method === 'GET') return json({ devices: (await env.DB.prepare('SELECT token, environment FROM devices').all()).results });
    if (request.method === 'POST') {
      const data = await readBody(request) as Record<string, unknown>;
      const token = text(data?.token, 'token', 200).toLowerCase();
      if (!/^[0-9a-f]{64,200}$/.test(token)) invalid('Invalid token');
      const environment = choice(data.environment, 'environment', ['sandbox', 'production']);
      const now = new Date().toISOString();
      await env.DB.prepare('INSERT INTO devices (token, environment, created_at, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(token) DO UPDATE SET environment = excluded.environment, updated_at = excluded.updated_at').bind(token, environment, now, now).run();
      return json({ registered: true }, 201);
    }
    throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
  }
  const device = /^\/v1\/devices\/([^/]+)$/.exec(path);
  if (device) {
    if (request.method !== 'DELETE') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
    query(url.searchParams, []);
    const removed = await env.DB.prepare('DELETE FROM devices WHERE token = ?').bind(device[1].toLowerCase()).run();
    return json({ removed: removed.meta.changes > 0 });
  }
  if (path === '/v1/quotes') {
    if (request.method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
    return quoteRoute(url);
  }
  if (path === '/v1/ingest' && request.method === 'GET') {
    const data: Record<string, unknown> = query(url.searchParams, fields);
    for (const key of ['tickers', 'tags']) if (typeof data[key] === 'string') data[key] = data[key] === '' ? [] : (data[key] as string).split(',');
    return ingest(data, env, ctx);
  }
  if (path === '/v1/stories') {
    if (request.method === 'GET') return list(url, env);
    if (request.method === 'POST') { query(url.searchParams, []); return ingest(await readBody(request), env, ctx); }
  }
  const match = /^\/v1\/stories\/([^/]+)$/.exec(path);
  if (match && request.method === 'GET') {
    query(url.searchParams, []);
    if (!uuid.test(match[1])) invalid('Invalid story id');
    const row = await env.DB.prepare('SELECT * FROM stories WHERE id = ?').bind(match[1]).first();
    if (!row) throw new ApiError(404, 'not_found', 'Story not found');
    return json({ story: story(row) });
  }
  if (match && request.method === 'DELETE') {
    query(url.searchParams, []);
    if (!uuid.test(match[1])) invalid('Invalid story id');
    const update = await env.DB.prepare('UPDATE stories SET retracted_at = ? WHERE id = ? AND retracted_at IS NULL').bind(new Date().toISOString(), match[1]).run();
    const row = await env.DB.prepare('SELECT * FROM stories WHERE id = ?').bind(match[1]).first();
    if (!row) throw new ApiError(404, 'not_found', 'Story not found');
    return json({ story: story(row), retracted: update.meta.changes > 0 });
  }
  if (match || path === '/v1/stories' || path === '/v1/ingest') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
  throw new ApiError(404, 'not_found', 'Route not found');
}
export default {
  async fetch(request: Request, env: Env, ctx?: ExecutionContext): Promise<Response> {
    let response: Response;
    try { response = await route(request, env, ctx); } catch (error) {
      response = error instanceof ApiError ? json({ error: { code: error.code, message: error.message } }, error.status) : json({ error: { code: 'internal_error', message: 'Internal server error' } }, 500);
    }
    const secured = new Response(response.body, response);
    secured.headers.set('Cache-Control', 'no-store');
    secured.headers.set('X-Content-Type-Options', 'nosniff');
    secured.headers.set('Referrer-Policy', 'no-referrer');
    secured.headers.set('X-Frame-Options', 'DENY');
    secured.headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
    secured.headers.set('Strict-Transport-Security', 'max-age=31536000');
    secured.headers.set('Vary', 'Authorization');
    if (response.status === 401) secured.headers.set('WWW-Authenticate', 'Bearer');
    return secured;
  },
};
