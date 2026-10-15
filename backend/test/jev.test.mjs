import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// The client keeps its cooldown under the home directory; tests must neither read nor write the real one.
process.env.HOME = mkdtempSync(join(tmpdir(), 'newswire-jev-'));
process.env.NEWSWIRE_CLASSIFIER_PROVIDER = 'jev';
const { ask, classifierIdentity, classifierUsage, retryTime } = await import('../../scripts/monitor/jev.mjs');

const questions = { topic: { criteria: { energy: 'Oil', other: 'Other' }, instructions: 'Choose' } };
test('retry delay honors a full-day free quota reset instead of hammering the provider', () => {
  const now = Date.parse('2026-10-13T00:00:00Z');
  assert.equal(retryTime('85927', now), now + 85927000);
  assert.equal(retryTime('Tue, 13 Oct 2026 01:00:00 GMT', now), now + 3600000);
  assert.equal(retryTime(null, now), now + 60000);
});
test('Zen tries the free Jev model first and validates its typed response', async t => {
  const saved = process.env.NEWSWIRE_ZEN_API_KEY;
  process.env.NEWSWIRE_ZEN_API_KEY = 'test-secret';
  t.after(() => { if (saved === undefined) delete process.env.NEWSWIRE_ZEN_API_KEY; else process.env.NEWSWIRE_ZEN_API_KEY = saved; });
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return Response.json({ answers: { topic: { choice: 'energy', confidence: 0.91 } } });
  });
  assert.equal((await ask('Oil production', questions)).topic.choice, 'energy');
  assert.equal(classifierIdentity, 'zen:jev-1.13');
  assert.equal(calls[0].url, 'https://opencode.ai/zen/v1/systemone');
  assert.equal(calls[0].body.model, 'jev-1.13-free');
  assert.equal(calls[0].body.questions.topic.type, 'choice');
});

test('a free-tier 429 falls back to paid Jev and later calls skip free until the reset', async t => {
  const models = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    const { model } = JSON.parse(init.body);
    models.push(model);
    return model === 'jev-1.13-free' ? new Response('{}', { status: 429, headers: { 'Retry-After': '86400' } }) : Response.json({ answers: { topic: { choice: 'energy', confidence: 0.9 } } });
  });
  const before = classifierUsage();
  assert.equal((await ask('Oil production', questions)).topic.choice, 'energy');
  assert.equal((await ask('Oil production', questions)).topic.choice, 'energy');
  assert.deepEqual(models, ['jev-1.13-free', 'jev-1.13', 'jev-1.13']);
  assert.equal(classifierUsage()['jev-1.13'] - before['jev-1.13'], 2);
});

test('when both models fail the error names both and hides provider text', async t => {
  t.mock.method(globalThis, 'fetch', async () => Response.json({ detail: { error_type: 'billing_error', message: 'private provider text' } }, { status: 402 }));
  await assert.rejects(ask('Oil production', questions), error => /jev-1\.13-free/.test(error.message) && /paid fallback: zen jev-1\.13 402; code: billing_error/.test(error.message) && !error.message.includes('private provider text'));
});

test('unknown choices and malformed confidence fail closed', async t => {
  for (const answer of [{ choice: 'invented', confidence: 0.9 }, { choice: 'energy', confidence: 2 }, { choice: 'energy', confidence: -0.1 }, { choice: 'energy', confidence: '0.9' }]) {
    t.mock.method(globalThis, 'fetch', async () => Response.json({ answers: { topic: answer } }));
    await assert.rejects(ask('News', questions), /invalid topic/);
    t.mock.restoreAll();
  }
});

test('truncated emoji and legacy malformed Unicode cannot poison classifier requests', async t => {
  const bodies = [];
  t.mock.method(globalThis, 'fetch', async (_url, init) => {
    const body = JSON.parse(init.body);
    bodies.push(body);
    assert.equal(body.state.isWellFormed(), true);
    assert.equal(body.questions.topic.instructions.isWellFormed(), true);
    return Response.json({ answers: { topic: { choice: 'energy', confidence: 0.9 } } });
  });
  const text = 'Shipping warning ' + '🌊'.slice(0, 1);
  await ask(text, { topic: { ...questions.topic, instructions: 'Choose\uDC00' } });
  await ask('Valid 🌊 shipping warning', questions);
  assert.equal(bodies[0].state, 'Shipping warning �');
  assert.equal(bodies[1].state, 'Valid 🌊 shipping warning');
});
