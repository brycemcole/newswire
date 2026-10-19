// Runs the Worker on Node with SQLite files in place of D1, for hosting on the Mini (workerd cannot run on 16 KB-page kernels).
import { createServer } from 'node:http';
import { readFile, readdir, mkdir } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';
import { extname, join, normalize } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual } from 'node:crypto';

const here = fileURLToPath(new URL('.', import.meta.url));
const dataDir = process.env.NEWSWIRE_DATA ?? join(homedir(), '.local', 'share', 'newswire-server');
const port = Number(process.env.PORT ?? 8787);
const webDir = process.env.NEWSWIRE_WEB ?? join(here, '..', '..', 'web');

const plain = value => value === undefined ? null : typeof value === 'boolean' ? Number(value) : value instanceof ArrayBuffer ? new Uint8Array(value) : value;

/** The subset of the D1 binding the Worker uses, over a local SQLite file. */
export class D1 {
  constructor(file) {
    this.db = new DatabaseSync(file);
    this.db.exec('PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = OFF;');
  }
  prepare(sql) { return new Statement(this.db, sql, []); }
  async batch(statements) {
    this.db.exec('BEGIN');
    try {
      const results = statements.map(statement => statement.runSync());
      this.db.exec('COMMIT');
      return results;
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  async exec(sql) { this.db.exec(sql); return { count: 1, duration: 0 }; }
}

class Statement {
  constructor(db, sql, params) { this.db = db; this.sql = sql; this.params = params; }
  bind(...params) { return new Statement(this.db, this.sql, params.map(plain)); }
  rows() { return this.db.prepare(this.sql).all(...this.params).map(row => ({ ...row })); }
  runSync() {
    if (/^\s*(SELECT|WITH|PRAGMA)\b|\bRETURNING\b/i.test(this.sql)) return { success: true, results: this.rows(), meta: { changes: 0 } };
    const info = this.db.prepare(this.sql).run(...this.params);
    return { success: true, results: [], meta: { changes: Number(info.changes), last_row_id: Number(info.lastInsertRowid) } };
  }
  async first(column) {
    const row = this.db.prepare(this.sql).get(...this.params);
    if (!row) return null;
    return column ? row[column] ?? null : { ...row };
  }
  async all() { return { success: true, results: this.rows(), meta: {} }; }
  async run() { return this.runSync(); }
  async raw() { return this.db.prepare(this.sql).all(...this.params).map(row => Object.values(row)); }
}

export async function migrate(db, dir) {
  db.db.exec('CREATE TABLE IF NOT EXISTS d1_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)');
  const applied = new Set(db.db.prepare('SELECT name FROM d1_migrations').all().map(row => row.name));
  for (const name of (await readdir(dir)).filter(file => file.endsWith('.sql')).sort()) {
    if (applied.has(name)) continue;
    db.db.exec('BEGIN');
    try {
      db.db.exec(await readFile(join(dir, name), 'utf8'));
      db.db.prepare('INSERT INTO d1_migrations (name, applied_at) VALUES (?, ?)').run(name, new Date().toISOString());
      db.db.exec('COMMIT');
    } catch (error) { db.db.exec('ROLLBACK'); throw new Error(`${name}: ${error.message}`); }
  }
}

const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };
const assets = {
  async fetch(request) {
    let path = normalize(decodeURIComponent(new URL(request.url).pathname)).replace(/^(\.\.[/\\])+/, '');
    if (path.endsWith('/')) path += 'index.html';
    try { return new Response(await readFile(join(webDir, path)), { headers: { 'Content-Type': types[extname(path)] ?? 'application/octet-stream' } }); }
    catch { return new Response('Not found', { status: 404 }); }
  },
};

export async function start() {
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  const { Compute } = await import(join(here, 'worker.mjs'));
  const DB = new D1(join(dataDir, 'newswire.sqlite')), BRAIN = new D1(join(dataDir, 'brain.sqlite'));
  await migrate(DB, join(here, '..', 'migrations'));
  await migrate(BRAIN, join(here, '..', 'brain'));
  const writer = process.env.WRITER_TOKEN ?? (await readFile(join(homedir(), '.config', 'newswire', 'writer-token'), 'utf8')).trim();
  const env = { DB, BRAIN, ASSETS: assets, WRITER_TOKEN: writer, ...(process.env.FRED_API_KEY ? { FRED_API_KEY: process.env.FRED_API_KEY } : {}) };
  env.AI = { async run(model, input) {
    const response = await fetch('https://bryce-newswire.bryce-e19.workers.dev/v1/brain/ai', {
      method: 'POST', headers: { Authorization: `Bearer ${writer}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...input, model }), signal: AbortSignal.timeout(60000),
    });
    if (!response.ok) throw new Error(`Workers AI HTTP ${response.status}`);
    const result = await response.json();
    return { response: result.text, usage: result.usage };
  } };
  const state = { waitUntil: promise => { Promise.resolve(promise).catch(error => console.error('waitUntil', error)); } };
  // The Durable Object class carries the AI broker and the cron entry point, so it serves every route here.
  const worker = new Compute(state, env);

  createServer(async (incoming, outgoing) => {
    try {
      const expected = process.env.NEWSWIRE_ORIGIN_TOKEN;
      if (expected && incoming.headers.host !== `127.0.0.1:${port}`) {
        const actual = Buffer.from(String(incoming.headers['x-newswire-origin'] ?? ''));
        const secret = Buffer.from(expected);
        if (actual.length !== secret.length || !timingSafeEqual(actual, secret)) {
          outgoing.writeHead(403).end('Forbidden');
          return;
        }
      }
      const chunks = [];
      let size = 0;
      for await (const chunk of incoming) {
        size += chunk.length;
        if (size > 2 * 1024 * 1024) { outgoing.writeHead(413).end('Request too large'); return; }
        chunks.push(chunk);
      }
      const host = incoming.headers['x-forwarded-host'] ?? incoming.headers.host ?? `127.0.0.1:${port}`;
      const proto = incoming.headers['x-forwarded-proto'] ?? 'https';
      const headers = new Headers(Object.entries(incoming.headers).flatMap(([key, value]) => Array.isArray(value) ? value.map(v => [key, v]) : value === undefined ? [] : [[key, value]]));
      const request = new Request(`${proto}://${host}${incoming.url}`, { method: incoming.method, headers, body: ['GET', 'HEAD'].includes(incoming.method) ? undefined : Buffer.concat(chunks) });
      const response = await worker.fetch(request);
      const body = Buffer.from(await response.arrayBuffer());
      outgoing.writeHead(response.status, Object.fromEntries([...response.headers].filter(([key]) => key !== 'content-length')));
      outgoing.end(incoming.method === 'HEAD' ? undefined : body);
    } catch (error) {
      console.error(error);
      outgoing.writeHead(500, { 'Content-Type': 'application/json' }).end('{"error":{"code":"internal_error","message":"Internal server error"}}');
    }
  }).listen(port, '127.0.0.1', () => console.log(`newswire server on 127.0.0.1:${port}`));

  // Matches the Worker's */15 cron trigger.
  const tick = () => worker.fetch(new Request('https://compute/__cron')).catch(error => console.error('scheduled', error));
  setTimeout(tick, 30000);
  setInterval(tick, 15 * 60000);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await start();
