import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { completionPrompt, decodeCompletion, model } from '../../scripts/ai/opencode.mjs';

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

test('free completion waits for a worker, authenticates both sides, and rejects paid results', async () => {
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
  assert.equal((await request('worker/result', { id: job.id, result: { model, choices: [{}], cost: 1 } })).status, 400);
  const result = { model, cost: 0, choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'Hello' } }] };
  assert.equal((await request('worker/result', { id: job.id, result })).status, 200);
  assert.deepEqual(await (await completion).json(), result);
  assert.equal((await request('worker/result', { id: job.id, result })).status, 404);
  assert.equal((await (await request('status')).json()).pending, 0);
  assert.equal((await request('chat/completions', { messages: [{ role: 'user', content: 7 }] })).status, 400);
});

test('function adapter preserves arguments and refuses unknown or disabled tools', () => {
  const body = { messages: [{ role: 'user', content: 'quote' }], tools: [{ type: 'function', function: { name: 'quote', parameters: { type: 'object' } } }] };
  const choice = decodeCompletion('{"tool_calls":[{"name":"quote","arguments":{"symbol":"SPY"}}]}', body);
  assert.equal(choice.finish_reason, 'tool_calls');
  assert.deepEqual(JSON.parse(choice.message.tool_calls[0].function.arguments), { symbol: 'SPY' });
  assert.throws(() => decodeCompletion('{"tool_calls":[{"name":"bash","arguments":{}}]}', body));
  assert.throws(() => decodeCompletion('{"tool_calls":[{"name":"quote","arguments":{}}]}', { ...body, tool_choice: 'none' }));
  assert.throws(() => decodeCompletion('{"content":""}', body));
  assert.match(completionPrompt(body), /Do not use OpenCode's built-in tools/);
});

test('structured answers remain valid when the model returns the requested JSON without an outer content field', () => {
  const value = { market: 'Conditional effect', stocks: [], questions: ['What changes?'] };
  const choice = decodeCompletion(JSON.stringify(value), { messages: [], tools: [] });
  assert.equal(choice.finish_reason, 'stop');
  assert.deepEqual(JSON.parse(choice.message.content), value);
  for (const invalid of ['{}', 'null', '{"content":null}', '{"tool_calls":[]}']) {
    assert.throws(() => decodeCompletion(invalid, { tools: [] }), /no answer/);
  }
});

test('Go fallback only accepts the configured subscription model', async () => {
  const claim = request('worker/claim', {});
  const completion = request('chat/completions', { messages: [{ role: 'user', content: 'hello' }] });
  const { job } = await (await claim).json();
  const result = { model: 'deepseek-v4.1-flash', provider: 'opencode-go', billing: 'subscription', choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'Hello from Go' } }] };
  for (const invalid of [{ ...result, provider: 'zen' }, { ...result, model: 'deepseek-v4-pro' }, { ...result, cost: 1 }]) {
    assert.equal((await request('worker/result', { id: job.id, result: invalid })).status, 400);
  }
  assert.equal((await request('worker/result', { id: job.id, result })).status, 200);
  assert.deepEqual(await (await completion).json(), result);
});

test('free success skips Go; failures fall back with the same request; cancellation stops fallback', async () => {
  const { complete, goComplete } = await import('../../scripts/ai/completion.mjs');
  const body = { model, messages: [{ role: 'user', content: 'Story lenses' }], max_tokens: 1200 };
  const freeResult = { model, cost: 0 };
  assert.equal(await complete(body, { free: async () => freeResult, go: () => assert.fail('unexpected Go') }), freeResult);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(complete(body, { signal: controller.signal, free: async () => { throw new Error('cancelled'); }, go: () => assert.fail('cancelled fallback') }), { name: 'AbortError' });
  const result = await complete(body, {
    free: async (_, options) => { assert.equal(options.timeout, 12000); throw new Error('rate limited'); },
    go: (requestBody, options) => goComplete(requestBody, { ...options, key: async () => 'test-key', fetchImpl: async (url, init) => {
      assert.equal(url, 'https://opencode.ai/inference/go/v1/chat/completions');
      assert.ok(init.headers['x-opencode-session']);
      const sent = JSON.parse(init.body);
      assert.equal(sent.model, 'deepseek-v4.1-flash');
      assert.deepEqual(sent.messages, body.messages);
      assert.equal(sent.max_tokens, 1200);
      return Response.json({ model: sent.model, choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: '{"market":"Conditional"}' } }], usage: { prompt_tokens: 10, completion_tokens: 4 } });
    } }),
  });
  assert.equal(result.provider, 'opencode-go');
  assert.equal(result.billing, 'subscription');
  assert.equal(result.cost, undefined);
});
