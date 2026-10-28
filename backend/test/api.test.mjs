import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

let mf;
let script;
const base = { external_id: 'example', title: 'A factual headline', source: 'Source', url: 'https://example.com/story', published_at: '2026-01-01T12:00:00Z' };
const options = (bindings = { WRITER_TOKEN: 'writer' }) => convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true, script, compatibilityDate: '2026-09-06', d1Databases: ['DB'], bindings, serviceBindings: { ASSETS: () => new Response('static shell') } }] });
const request = (path, token = 'reader', init = {}) => mf.dispatchFetch(`https://newswire.test${path}`, { ...init, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...init.headers } });
const post = (data, token = 'writer') => request('/v1/stories', token, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
test('market pulse is authenticated, replays receipt times, and updates after new stories', async () => {
  const path = '/v1/market-pulse?as_of=2026-10-12T11:00:00Z';
  assert.equal((await request(path, null)).status, 401);
  for (const q of ['as_of=bad', 'as_of=2040-01-01T00:00:00Z', 'symbol=UNKNOWN', 'symbol=SPY&symbol=QQQ', 'unknown=yes']) assert.equal((await request(`/v1/market-pulse?${q}`)).status, 400);
  const db = await mf.getD1Database('DB');
  const ids = [];
  try {
    for (const [title, received, suffix] of [['Missile attack hits Saudi oil facilities', '2026-10-12T10:01:00.000Z', 'one'], ['China imposes new tariffs', '2026-10-12T11:02:00.000Z', 'two']]) {
      const data = await (await post({ ...base, external_id: `pulse-${suffix}`, url: `https://example.com/pulse-${suffix}`, title, tags: ['headlines'], published_at: '2026-10-12T10:00:00Z' })).json();
      ids.push(data.story.id);
      await db.prepare('UPDATE stories SET received_at = ? WHERE id = ?').bind(received, data.story.id).run();
    }
    const beforeResponse = await request(path);
    assert.equal(beforeResponse.status, 200);
    assert.match(beforeResponse.headers.get('Cache-Control'), /no-store/);
    const before = await beforeResponse.json();
    assert.equal(before.status, 'available');
    assert.equal(before.coverage.matched_stories, 1);
    const after = await (await request('/v1/market-pulse?as_of=2026-10-12T11:03:00Z')).json();
    assert.equal(after.coverage.matched_stories, 2);
    assert.ok(after.score < before.score);
    const tool = await (await request('/v1/data/market/pulse?as_of=2026-10-12T11:00:00Z&symbol=XLE')).json();
    assert.match(tool.text, /XLE market pulse/);
    assert.equal(tool.as_of, '2026-10-12T11:00:00.000Z');
  } finally {
    for (const id of ids) await db.prepare('DELETE FROM stories WHERE id = ?').bind(id).run();
  }
});
before(async () => {
  script = (await build({ entryPoints: ['src/index.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
  mf = new Miniflare(options());
  const db = await mf.getD1Database('DB');
  for (const file of (await readdir(new URL('../migrations/', import.meta.url))).sort()) {
    const migration = await readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8');
    await db.batch(migration.split(';').filter(s => s.trim()).map(s => db.prepare(s)));
  }
  await db.batch([
    db.prepare("INSERT INTO attested_devices (key_id, public_key, created_at, last_seen_at) VALUES ('test', 'x', 'now', 'now')"),
    db.prepare('INSERT INTO sessions (token_hash, key_id, expires_at) VALUES (?, ?, ?)').bind(createHash('sha256').update('reader').digest('hex'), 'test', Date.now() + 3600000),
    db.prepare('INSERT INTO sessions (token_hash, key_id, expires_at) VALUES (?, ?, ?)').bind(createHash('sha256').update('expired').digest('hex'), 'test', Date.now() - 1000),
  ]);
});
after(async () => { await mf?.dispose(); });

test('research ledger is reader protected and mutations are writer-only without accepting backdated snapshots', async () => {
  assert.equal((await request('/v1/research?symbol=SPY', null)).status, 401);
  const empty = await request('/v1/research?symbol=SPY');
  assert.equal(empty.status, 200);
  const payload = await empty.json();
  assert.equal(payload.symbol, 'SPY');
  assert.equal(payload.latest, null);
  assert.equal(payload.performance.settled, 0);
  assert.equal(payload.performance.candidate_status, 'adaptive learning');
  assert.ok(payload.current);
  assert.equal(payload.current.learning.model, 'forecast-adaptive-v2');
  assert.equal(payload.current.learning.settled, 0);
  for (const q of ['symbol=INVALID', 'symbol=SPY&symbol=QQQ', 'as_of=2020-01-01']) {
    assert.equal((await request(`/v1/research?${q}`)).status, 400);
  }
  for (const action of ['capture', 'settle']) {
    assert.equal((await request(`/v1/research/${action}`, 'reader', { method: 'POST' })).status, 403);
    assert.equal((await request(`/v1/research/${action}`, 'writer')).status, 405);
  }
  const mutation = body => ({ method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await request('/v1/research/capture', 'writer', mutation({ symbol: 'SPY', snapshot: { as_of: '2020-01-01' } }))).status, 400);
  assert.equal((await request('/v1/research/settle', 'writer', mutation({ symbol: 'SPY', prices: { OTHER: {} } }))).status, 400);
  assert.equal((await request('/v1/market-pulse/snapshot?as_of=2020-01-01', 'writer')).status, 400);
});

test('impact retention and backend availability preserve evidence without backdating late delivery', async () => {
  const now = Date.now(), id = 'abcdef0123456789', olderId = 'abcdef9876543210';
  const db = await mf.getD1Database('DB');
  const old = new Date(now - 20 * 86400000).toISOString();
  await db.prepare('INSERT INTO pulse_impacts (id,title,source,url,published_at,received_at,direction,channel,size,confidence,classified_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)')
    .bind(olderId, 'Old evidence', 'Source', 'https://example.com/old', old, old, -1, 'energy', 'minor', 0.6, old).run();
  try {
    const before = new Date(now - 3600000).toISOString();
    const response = await request('/v1/market-pulse/impacts', 'writer', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ impacts: [{ id, title: 'Delayed classification delivery', source: 'Source', url: 'https://example.com/delayed', published_at: before, received_at: before,
        classified_at: before, classifier_version: 'test-model-v1', direction: -1, channel: 'energy', size: 'minor', confidence: 0.6 }] }) });
    assert.equal(response.status, 201);
    const saved = await db.prepare('SELECT * FROM pulse_impacts WHERE id=?').bind(id).first();
    assert.ok(Date.parse(saved.classified_at) >= now);
    assert.equal(saved.source_classified_at, before);
    assert.equal(saved.classifier_version, 'test-model-v1');
    assert.ok(await db.prepare('SELECT id FROM pulse_impacts WHERE id=?').bind(olderId).first());
  } finally {
    await db.prepare('DELETE FROM pulse_impacts WHERE id IN (?,?)').bind(id, olderId).run();
  }
});

test('authentication, reader/writer separation, fail closed and public shell', async () => {
  assert.equal((await request('/health', null)).status, 200);
  assert.equal(await (await request('/', null)).text(), 'static shell');
  for (const token of [null, 'wrong', 'expired']) assert.equal((await request('/v1/stories', token)).status, 401);
  assert.equal((await post(base, 'reader')).status, 403);
  assert.equal((await request('/v1/ingest', 'reader')).status, 403);
  assert.equal((await request('/v1/stories', 'writer')).status, 200);
  for (const bindings of [{}, { WRITER_TOKEN: ' ' }]) {
    const closed = new Miniflare(options(bindings));
    try { assert.equal((await closed.dispatchFetch('https://test/v1/stories', { headers: { Authorization: 'Bearer writer' } })).status, 503); } finally { await closed.dispose(); }
  }
});

test('article extraction requires a reader session and a public URL', async () => {
  assert.equal((await request('/v1/extract?url=https://example.com/a', null)).status, 401);
  for (const query of ['', 'url=https://127.0.0.1/a', 'url=file:///etc/passwd', 'url=https://example.com/a&extra=1'])
    assert.equal((await request(`/v1/extract?${query}`)).status, 400, query);
});

test('strict validation and bounded requests do not insert', async () => {
  const cases = [null, [], { ...base, extra: true }, { ...base, title: ' ' }, { ...base, title: 'x'.repeat(301) }, { ...base, url: 'javascript:alert(1)' }, { ...base, url: 'https://user:pass@example.com' }, { ...base, url: `https://example.com/${'x'.repeat(4096)}` }, { ...base, published_at: '2026-02-30T12:00:00Z' }, { ...base, published_at: '2026-01-01' }, { ...base, published_at: new Date(Date.now() + 600000).toISOString() }, { ...base, category: 'bad' }, { ...base, priority: null }, { ...base, tickers: 'AAPL' }, { ...base, tags: Array(21).fill('tag') }, { ...base, body: 'a'.repeat(20001) }];
  for (const data of cases) assert.equal((await post(data)).status, 400, JSON.stringify(data)?.slice(0, 120));
  assert.equal((await request('/v1/stories', 'writer', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{' })).status, 400);
  assert.equal((await post({ ...base, body: 'x'.repeat(140000) })).status, 413);
  assert.equal((await request(`/v1/ingest?body=${'x'.repeat(8000)}`, 'writer')).status, 413);
  for (const query of ['limit=0', 'limit=101', 'limit=1&limit=2', 'cursor=bad', 'category=no', 'priority=no', 'q=', 'token=writer']) assert.equal((await request(`/v1/stories?${query}`)).status, 400);
  const db = await mf.getD1Database('DB');
  assert.equal((await db.prepare('SELECT count(*) AS n FROM stories').first()).n, 0);
});

test('atomic concurrent dedup on both unique keys and normalized URLs', async () => {
  const responses = await Promise.all(Array.from({ length: 12 }, () => post(base)));
  assert.equal(responses.filter(r => r.status === 201).length, 1);
  assert.equal(responses.filter(r => r.status === 200).length, 11);
  const bodies = await Promise.all(responses.map(r => r.json()));
  assert.equal(new Set(bodies.map(b => b.story.id)).size, 1);
  assert.equal(bodies[0].story.published_at, '2026-01-01T12:00:00.000Z');
  const normalized = await post({ ...base, external_id: 'other', url: 'https://EXAMPLE.com:443/story#fragment', title: 'Must not overwrite' });
  assert.equal(normalized.status, 200);
  assert.equal((await normalized.json()).story.title, base.title);
  const urls = await Promise.all(Array.from({ length: 10 }, (_, i) => post({ ...base, external_id: `url-${i}`, url: 'https://example.com/concurrent' })));
  assert.equal(urls.filter(r => r.status === 201).length, 1);
  const ids = await Promise.all(Array.from({ length: 10 }, (_, i) => post({ ...base, external_id: 'shared-id', url: `https://example.com/distinct-${i}` })));
  assert.equal(ids.filter(r => r.status === 201).length, 1);
  const db = await mf.getD1Database('DB');
  assert.equal((await db.prepare('SELECT count(*) AS n FROM stories').first()).n, 3);
});

test('GET ingestion, detail, filters, literal SQL search, routes and headers', async () => {
  const data = { ...base, external_id: 'get', url: 'https://example.com/get', category: 'technology', priority: 'breaking', tickers: 'AAPL,MSFT', tags: 'ai,cloud', source: 'UniquePublisher', agent: 'UniqueAgent', title: "100% growth isn't certain" };
  const response = await request(`/v1/ingest?${new URLSearchParams(data)}`, 'writer');
  assert.equal(response.status, 201);
  const { story } = await response.json();
  assert.deepEqual(story.tickers, ['AAPL', 'MSFT']);
  assert.equal((await (await request(`/v1/stories/${story.id}`)).json()).story.id, story.id);
  assert.equal((await request('/v1/stories/00000000-0000-4000-8000-000000000000')).status, 404);
  for (const filter of ['category=technology&priority=breaking&ticker=AAPL', 'q=100%25', 'q=isn%27t', 'q=UniquePublisher', 'q=UniqueAgent']) {
    assert.equal((await (await request(`/v1/stories?${filter}`)).json()).stories.length, 1);
  }
  assert.equal((await (await request('/v1/stories?q=%27%20OR%201%3D1--')).json()).stories.length, 0);
  assert.equal((await request('/v1/ingest?title=a&title=b', 'writer')).status, 400);
  assert.equal((await request('/v1/stories', 'writer', { method: 'DELETE' })).status, 405);
  assert.equal((await request('/v1/unknown')).status, 404);
  assert.equal((await request('/v1/stories', null, { method: 'OPTIONS' })).status, 204);
  for (const path of ['/v1/stories', '/v1/unknown', '/']) {
    const r = await request(path);
    assert.equal(r.headers.get('cache-control'), 'no-store');
    assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(r.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(r.headers.get('content-security-policy'), "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
  }
});

test('stable timestamp/id keyset pagination under new arrivals', async () => {
  for (let i = 0; i < 7; i++) assert.equal((await post({ ...base, external_id: `page-${i}`, url: `https://example.com/page-${i}`, category: 'science', published_at: i < 5 ? '2026-02-01T12:00:00Z' : '2026-01-31T12:00:00Z' })).status, 201);
  const all = (await (await request('/v1/stories?category=science')).json()).stories;
  assert.deepEqual(all.map(s => `${s.published_at}/${s.id}`), all.map(s => `${s.published_at}/${s.id}`).sort().reverse());
  let page = await (await request('/v1/stories?category=science&limit=2')).json();
  const seen = [...page.stories];
  await post({ ...base, external_id: 'new-arrival', url: 'https://example.com/new', category: 'science', published_at: '2026-03-01T12:00:00Z' });
  while (page.next_cursor) {
    page = await (await request(`/v1/stories?category=science&limit=2&cursor=${page.next_cursor}`)).json();
    seen.push(...page.stories);
  }
  assert.deepEqual(seen.map(s => s.id), all.map(s => s.id));
});

test('tag, agent and time filters narrow the wire precisely', async () => {
  await post({ ...base, external_id: 'filter-a', url: 'https://example.com/filter-a', category: 'economy', tags: ['debt'], agent: 'desk-a', source: 'Filter Wire', published_at: '2026-04-01T12:00:00Z' });
  await post({ ...base, external_id: 'filter-b', url: 'https://example.com/filter-b', category: 'economy', tags: ['inflation'], agent: 'desk-b', source: 'Filter Wire Extra', published_at: '2026-04-02T12:00:00Z' });
  const cases = [['tag=debt', 1], ['tag=debt&agent=desk-b', 0], ['agent=desk-a', 1], ['source=Filter%20Wire', 1], ['source=Filter%20Wire&agent=desk-b', 0], ['since=2026-04-02T00:00:00Z', 1], ['until=2026-04-01T12:00:00Z&agent=desk-a', 1], ['since=2026-04-01T12:00:00Z&until=2026-04-02T12:00:00Z', 2], ['tag=debt&since=2026-04-02T00:00:00Z', 0]];
  for (const [filter, count] of cases) assert.equal((await (await request(`/v1/stories?${filter}`)).json()).stories.length, count, filter);
  for (const bad of ['since=not-a-time', 'until=not-a-time', 'retracted=sometimes', 'tag=', 'source=']) assert.equal((await request(`/v1/stories?${bad}`)).status, 400);
});

test('retraction tombstones a story without deleting or altering it', async () => {
  const created = await post({ ...base, external_id: 'retract-me', url: 'https://example.com/retract-me', tags: ['doomed'], agent: 'desk-a', published_at: '2026-04-03T12:00:00Z' });
  const { story } = await created.json();
  const missing = '00000000-0000-4000-8000-000000000009';
  assert.equal((await request(`/v1/stories/${story.id}`, 'reader', { method: 'DELETE' })).status, 403);
  assert.equal((await request(`/v1/stories/${missing}`, 'writer', { method: 'DELETE' })).status, 404);
  assert.equal((await request('/v1/stories/nope', 'writer', { method: 'DELETE' })).status, 400);
  const removed = await (await request(`/v1/stories/${story.id}`, 'writer', { method: 'DELETE' })).json();
  assert.equal(removed.retracted, true);
  assert.match(removed.story.retracted_at, /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(removed.story.title, base.title);
  assert.equal((await (await request('/v1/stories?tag=doomed')).json()).stories.length, 0);
  assert.equal((await (await request('/v1/stories?tag=doomed&retracted=only')).json()).stories.length, 1);
  assert.equal((await (await request('/v1/stories?tag=doomed&retracted=include')).json()).stories.length, 1);
  assert.equal((await (await request(`/v1/stories/${story.id}`)).json()).story.retracted_at, removed.story.retracted_at);
  assert.equal((await (await request(`/v1/stories/${story.id}`, 'writer', { method: 'DELETE' })).json()).retracted, false);
});

test('brokerage alert symbols round trip, validate and clear on removal', async () => {
  const token = 'b'.repeat(64);
  const register = stock_symbols => request('/v1/devices', 'reader', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token, environment: 'sandbox', stock_symbols }) });
  assert.equal((await register(['AAPL', 'AAPL', 'MSFT'])).status, 201);
  let result = await (await request('/v1/devices', 'writer')).json();
  assert.deepEqual(JSON.parse(result.devices.find(d => d.token === token).stock_symbols), ['AAPL', 'MSFT']);
  assert.equal((await register(['bad symbol'])).status, 400);
  assert.equal((await register([])).status, 201);
  result = await (await request('/v1/devices', 'writer')).json();
  assert.deepEqual(JSON.parse(result.devices.find(d => d.token === token).stock_symbols), []);
  assert.equal((await request('/v1/devices', 'reader')).status, 403);
});

test('data layer: tool catalog, wire full-text search, retraction filter and MCP', async () => {
  assert.equal((await request('/v1/data/tools.json', null)).status, 401);
  const catalog = await (await request('/v1/data/tools.json')).json();
  const names = catalog.tools.map(t => t.name);
  for (const name of ['macro', 'series', 'series_search', 'calendar', 'fed_odds', 'yield_curve', 'board', 'quote', 'screener', 'stock_screens', 'wire_search', 'sec_filings', 'insider_trades', 'holders', 'contracts', 'chokepoints', 'world_economy']) assert.ok(names.includes(name), name);
  assert.deepEqual(catalog.tools.find(t => t.name === 'series').parameters.required, ['id']);
  const story = { ...base, external_id: 'fts-1', url: 'https://example.com/fts-1', title: 'Powell signals patience on rate cuts', summary: 'The Federal Reserve chair spoke on inflation.', published_at: new Date(Date.now() - 3600000).toISOString() };
  const created = await (await post(story)).json();
  await post({ ...story, external_id: 'fts-2', url: 'https://example.com/fts-2', title: 'Retracted Powell item' }).then(r => r.json()).then(({ story: s }) => request(`/v1/stories/${s.id}`, 'writer', { method: 'DELETE' }));
  const found = await (await request('/v1/data/wire/search?q=powell%20cuts')).json();
  assert.equal(found.sections[0].rows.length, 1);
  assert.equal(found.sections[0].rows[0].story, created.story.id);
  assert.match(found.text, /Powell signals patience/);
  assert.match(found.as_of, /^\d{4}-/);
  assert.equal((await (await request('/v1/data/wire/search?q=inflat')).json()).sections[0].rows.length, 1);
  assert.equal((await request('/v1/data/wire/search')).status, 400);
  assert.equal((await request('/v1/data/wire/search?q=x&bogus=1')).status, 400);
  assert.equal((await request('/v1/data/nowhere')).status, 404);
  assert.match((await (await request('/v1/data/tool/wire_search?q=powell')).json()).text, /Powell/);
  assert.equal((await request('/v1/data/tool/nope')).status, 404);
  assert.equal((await request('/v1/data/board/moon')).status, 400);
  const rpc = (body, token = 'reader') => request('/v1/mcp', token, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }, null)).status, 401);
  const init = await (await rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } })).json();
  assert.equal(init.result.serverInfo.name, 'newswire-data');
  assert.equal((await rpc({ jsonrpc: '2.0', method: 'notifications/initialized' })).status, 202);
  const listed = await (await rpc({ jsonrpc: '2.0', id: 2, method: 'tools/list' })).json();
  assert.ok(listed.result.tools.some(t => t.name === 'wire_search' && t.inputSchema.required.includes('q')));
  const called = await (await rpc({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'wire_search', arguments: { q: 'powell' } } })).json();
  assert.equal(called.result.isError, false);
  assert.match(called.result.content[0].text, /Powell signals patience/);
  const bad = await (await rpc({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'wire_search', arguments: { nope: 1 } } })).json();
  assert.equal(bad.result.isError, true);
  assert.equal((await (await rpc({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'nope' } })).json()).error.code, -32602);
});

test('ship positions ingest for writers and read back through the ships tool; devices keep muted topics', async () => {
  const ship = { mmsi: '123456789', name: 'TEST TANKER', kind: 'Tanker', lat: 26.5, lon: 56.3, speed: 12.4, course: 280, at: new Date().toISOString() };
  const send = (body, token = 'writer') => request('/v1/ships', token, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await send({ area: 'hormuz', ships: [ship] }, 'reader')).status, 403);
  assert.equal((await send({ area: 'mars', ships: [ship] })).status, 400);
  assert.equal((await send({ area: 'hormuz', ships: [{ ...ship, lat: 200 }] })).status, 400);
  assert.equal((await send({ area: 'hormuz', ships: [ship, { ...ship, mmsi: '2', speed: 0, kind: 'Cargo' }] })).status, 201);
  const result = await (await request('/v1/data/ships?area=hormuz')).json();
  assert.equal(result.map.pins.length, 2);
  assert.match(result.note, /2 vessels/);
  assert.equal(result.sections[1].rows[0].label, 'TEST TANKER');
  const token = 'c'.repeat(64);
  const register = body => request('/v1/devices', 'reader', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token, environment: 'sandbox', ...body }) });
  assert.equal((await register({ muted_topics: ['crypto', 'world'] })).status, 201);
  assert.equal((await register({ stock_symbols: ['AAPL'] })).status, 201);
  const device = (await (await request('/v1/devices', 'writer')).json()).devices.find(d => d.token === token);
  assert.deepEqual(JSON.parse(device.muted_topics), ['crypto', 'world']);
  assert.equal((await register({ muted_topics: ['Bad Topic'] })).status, 400);
});

test('economic history requires writer auth and makes missing monthly forecasts available', async () => {
  const date = new Date(Date.now() - 20 * 86400000).toISOString().slice(0, 10);
  const body = JSON.stringify({ date, rows: [{ label: 'USD Nonfarm Payrolls', actual: '29K', forecast: '89K', previous: '133K' }] });
  const init = { method: 'POST', headers: { 'Content-Type': 'application/json' }, body };
  assert.equal((await request('/v1/econ/history', 'reader', init)).status, 403);
  assert.equal((await request('/v1/econ/history', 'writer', init)).status, 201);
  const history = await (await request('/v1/data/economic/history?q=payrolls&countries=USD', 'reader')).json();
  assert.equal(history.sections[0].rows[0].forecast, '89K');
  const releases = await (await request('/v1/data/releases?countries=USD', 'reader')).json();
  assert.match(releases.text, /Nonfarm Payrolls: 29K.*Forecast 89K/);
  assert.equal(releases.sections[0].rows[0].actual, '29K');
  assert.equal((await request('/v1/econ/history', 'writer', { ...init, body: JSON.stringify({ date: '2026-02-31', rows: [] }) })).status, 400);
});

test('collector snapshots require writer auth and remain attributed through source search', async () => {
  const init = body => ({ method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const source = { rows: [{ label: 'Payrolls fall below forecasts', value: 'Publisher', url: 'https://news.google.com/rss/articles/test', date: new Date().toISOString(), detail: 'Reported consensus' }] };
  assert.equal((await request('/v1/econ/sources', 'reader', init(source))).status, 403);
  assert.equal((await request('/v1/econ/sources', 'writer', init(source))).status, 201);
  const result = await (await request('/v1/data/sources/search?q=payrolls', 'reader')).json();
  assert.equal(result.sections[0].rows[0].value, 'Publisher');
  assert.match(result.note, /not an exhaustive web search/);
  assert.equal((await request('/v1/econ/series', 'reader', init({ id: 'UNRATE', observations: [{ date: '2026-09-01', value: 4.2 }] }))).status, 403);
  assert.equal((await request('/v1/econ/series', 'writer', init({ id: 'UNRATE', observations: [{ date: '2026-09-01', value: 4.2 }] }))).status, 201);
  assert.equal((await request('/v1/econ/series', 'writer', init({ id: 'UNRATE', observations: [{ date: '2026-02-31', value: 4.2 }] }))).status, 400);
});

test('price watches and live activity tokens validate, persist and preserve older registrations', async () => {
  const token = 'c'.repeat(64);
  const watch = { id: 'watch-one', symbol: 'AAPL261218C00250000', direction: 'above', target: 5 };
  const activity = { watch_id: watch.id, token: 'd'.repeat(64), expires_at: Math.floor(Date.now() / 1000) + 3600 };
  const register = fields => request('/v1/devices', 'reader', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token, environment: 'sandbox', ...fields }) });
  assert.equal((await register({ price_watches: [watch], live_activities: [activity] })).status, 201);
  assert.equal((await register({ stock_symbols: ['MSFT'] })).status, 201);
  const result = await (await request('/v1/devices', 'writer')).json();
  const device = result.devices.find(d => d.token === token);
  assert.deepEqual(JSON.parse(device.price_watches), [watch]);
  assert.deepEqual(JSON.parse(device.live_activities), [activity]);
  for (const price_watches of [[{ ...watch, target: -1 }], [{ ...watch, direction: 'sideways' }], [watch, watch], [{ ...watch, symbol: 'bad symbol' }]]) {
    assert.equal((await register({ price_watches })).status, 400);
  }
  assert.equal((await register({ price_watches: [watch], live_activities: [{ ...activity, watch_id: 'missing' }] })).status, 400);
  const movement = { id: 'percent-watch', symbol: 'SPY', direction: 'either', percent: 1 };
  assert.equal((await register({ price_watches: [movement], live_activities: [] })).status, 201);
  const saved = (await (await request('/v1/devices', 'writer')).json()).devices.find(d => d.token === token);
  assert.deepEqual(JSON.parse(saved.price_watches), [movement]);
  for (const percent of [-1, 0, 0.1, 51, '1']) {
    assert.equal((await register({ price_watches: [{ ...movement, percent }] })).status, 400);
  }
  assert.equal((await register({ price_watches: [{ ...movement, target: 500 }] })).status, 400);
  assert.equal((await register({ price_watches: [], live_activities: [] })).status, 201);
});

test('session alert preferences persist, preserve older clients and clear explicitly', async () => {
  const token = 'f'.repeat(64), alert = { id: 'session-test', kind: 'preopen', minutes: 15 };
  const register = fields => request('/v1/devices', 'reader', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token, environment: 'sandbox', ...fields }) });
  assert.equal((await request('/v1/market-session', null)).status, 401);
  assert.equal((await request('/v1/market-session')).status, 200);
  assert.equal((await register({ session_alerts: [alert] })).status, 201);
  assert.equal((await register({ stock_symbols: ['SPY'] })).status, 201);
  const registered = async () => (await (await request('/v1/devices', 'writer')).json()).devices.find(d => d.token === token);
  assert.deepEqual(JSON.parse((await registered()).session_alerts), [alert]);
  assert.equal((await register({ session_alerts: [{ ...alert, minutes: -5 }] })).status, 400);
  assert.equal((await register({ session_alerts: [] })).status, 201);
  assert.deepEqual(JSON.parse((await registered()).session_alerts), []);
});
