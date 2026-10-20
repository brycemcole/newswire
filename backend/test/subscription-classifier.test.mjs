import assert from 'node:assert/strict';
import { test } from 'node:test';

process.env.NEWSWIRE_CLASSIFIER_PROVIDER = 'opencode-go';
process.env.NEWSWIRE_GO_API_KEY = 'test-only';
const { ask, classifierIdentity, classifierUsage } = await import('../../scripts/monitor/jev.mjs');
const questions = { topic: { criteria: { energy: 'Oil', other: 'Other' }, instructions: 'Choose' } };
const response = content => Response.json({ model: 'deepseek-v4.1-flash', choices: [{ finish_reason: 'stop', message: { role: 'assistant', content } }] });

test('subscription classification uses only Go, validates answers and reports actual model', async t => {
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    assert.equal(url, 'https://opencode.ai/inference/go/v1/chat/completions');
    const body = JSON.parse(init.body);
    assert.equal(body.model, 'deepseek-v4.1-flash');
    assert.equal(body.stream, false);
    assert.ok(init.signal);
    assert.deepEqual(JSON.parse(body.messages[1].content), { state: 'Oil production', questions });
    return response('{"topic":{"choice":"energy","confidence":0.91}}');
  });
  assert.equal(classifierIdentity, 'opencode-go:deepseek-v4.1-flash');
  assert.equal((await ask('Oil production', questions)).topic.choice, 'energy');
  assert.equal(classifierUsage()['deepseek-v4.1-flash'], 1);
});

test('subscription failures never attempt a paid credit route; queue recovers', async t => {
  let calls = 0;
  t.mock.method(globalThis, 'fetch', async url => {
    assert.equal(url, 'https://opencode.ai/inference/go/v1/chat/completions');
    calls++;
    return new Response('{}', { status: 402 });
  });
  await assert.rejects(ask('Oil', questions), /Go HTTP 402/);
  assert.equal(calls, 1);
  t.mock.restoreAll();
  t.mock.method(globalThis, 'fetch', async () => response('{"topic":{"choice":"other","confidence":0.8}}'));
  assert.equal((await ask('News', questions)).topic.choice, 'other');
});

test('missing, malformed and out-of-range subscription verdicts fail closed', async t => {
  for (const answer of ['{}', 'not JSON', '{"topic":{"choice":"invented","confidence":0.9}}', '{"topic":{"choice":"energy","confidence":2}}', '{"topic":{"choice":"energy","confidence":-0.1}}', '{"topic":{"choice":"energy","confidence":"0.9"}}']) {
    let calls = 0;
    t.mock.method(globalThis, 'fetch', async () => { calls++; return response(answer); });
    await assert.rejects(ask('News', questions));
    assert.equal(calls, 1);
    t.mock.restoreAll();
  }
});
