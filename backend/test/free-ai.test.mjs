import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { complete, model } from '../../scripts/ai/deepseek.mjs';

let mf;
const request = (path, body, token = 'writer') => mf.dispatchFetch(`https://newswire.test/v1/ai/${path}`, {
  method: body === undefined ? 'GET' : 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
});
before(async () => {
  const script = (await build({ entryPoints: ['src/index.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true, script, compatibilityDate: '2026-09-06',
    d1Databases: ['DB'], durableObjects: { COMPUTE: { className: 'Compute', useSQLite: true } },
    bindings: { WRITER_TOKEN: 'writer' }, serviceBindings: { ASSETS: () => new Response('shell') } }] }));
  const db = await mf.getD1Database('DB');
  await db.exec('CREATE TABLE sessions (token_hash TEXT, expires_at INTEGER)');
  await db.prepare('INSERT INTO sessions VALUES (?, ?)').bind(createHash('sha256').update('reader').digest('hex'), Date.now() + 3600000).run();
});
after(async () => { await mf?.dispose(); });

test('free completion waits for a worker, authenticates both sides, and rejects other models', async () => {
  assert.equal((await request('chat/completions', { messages: [{ role: 'user', content: 'hello' }] }, 'reader')).status, 503);
  assert.equal((await request('worker/claim', {}, 'reader')).status, 403);
  const claim = request('worker/claim', {});
  for (let attempt = 0; attempt < 20; attempt++) {
    if ((await (await request('status')).json()).available) break;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal((await request('chat/completions', { model: 'deepseek-v4-pro', messages: [{ role: 'user', content: 'hello' }] })).status, 400);
  const completion = request('chat/completions', { messages: [{ role: 'user', content: 'hello' }], max_tokens: 100 }, 'reader');
  const { job } = await (await claim).json();
  assert.equal(job.body.model, model);
  assert.equal(job.body.messages[0].content, 'hello');
  assert.equal((await request('worker/result', { id: job.id, result: { model: 'deepseek-v4-pro', provider: 'deepseek', choices: [{}] } })).status, 400);
  const result = { model, provider: 'deepseek', choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'Hello' } }] };
  assert.equal((await request('worker/result', { id: job.id, result })).status, 200);
  assert.deepEqual(await (await completion).json(), result);
  assert.equal((await request('worker/result', { id: job.id, result })).status, 404);
  assert.equal((await (await request('status')).json()).pending, 0);
  assert.equal((await request('chat/completions', { messages: [{ role: 'user', content: 7 }] })).status, 400);
});

test('results must come from the configured DeepSeek model', async () => {
  const claim = request('worker/claim', {});
  const completion = request('chat/completions', { messages: [{ role: 'user', content: 'hello' }] });
  const { job } = await (await claim).json();
  const result = { model, provider: 'deepseek', choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'Hello' } }] };
  for (const invalid of [{ ...result, provider: 'zen' }, { ...result, model: 'deepseek-v4-pro' }, { ...result, choices: [] }]) {
    assert.equal((await request('worker/result', { id: job.id, result: invalid })).status, 400);
  }
  assert.equal((await request('worker/result', { id: job.id, result })).status, 200);
  assert.deepEqual(await (await completion).json(), result);
});

test('the DeepSeek client forwards tools, disables thinking, retries transient errors and rejects truncation', async () => {
  const body = { messages: [{ role: 'user', content: 'quote' }], tools: [{ type: 'function', function: { name: 'quote', parameters: { type: 'object' } } }], max_tokens: 1200 };
  const sent = [];
  const answer = { model, choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'ok' } }], usage: { prompt_tokens: 7, completion_tokens: 2 } };
  const fetchImpl = async (url, init) => { sent.push({ url, headers: init.headers, body: JSON.parse(init.body) }); return sent.length === 1 ? new Response('{}', { status: 503 }) : Response.json(answer); };
  const result = await complete(body, { fetchImpl, apiKey: async () => 'k' });
  assert.equal(sent.length, 2);
  assert.equal(sent[1].url, 'https://api.deepseek.com/chat/completions');
  assert.equal(sent[1].headers.Authorization, 'Bearer k');
  assert.equal(sent[1].body.model, model);
  assert.deepEqual(sent[1].body.thinking, { type: 'disabled' });
  assert.deepEqual(sent[1].body.tools, body.tools);
  assert.deepEqual(result, { model, provider: 'deepseek', choices: answer.choices, usage: { prompt_tokens: 7, completion_tokens: 2 } });
  await assert.rejects(complete(body, { fetchImpl: async () => Response.json({ choices: [{ finish_reason: 'length', message: { content: 'cut' } }] }), apiKey: async () => 'k' }), /incomplete/);
  await assert.rejects(complete(body, { fetchImpl: async () => new Response('{}', { status: 401 }), apiKey: async () => 'k' }), /HTTP 401/);
});
