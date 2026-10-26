import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { complete as freeComplete, model as freeModel } from './opencode.mjs';

export const goModel = 'deepseek-v4.1-flash';

export async function goKey() {
  if (process.env.NEWSWIRE_GO_API_KEY?.trim()) return process.env.NEWSWIRE_GO_API_KEY.trim();
  const config = JSON.parse(await readFile(join(homedir(), '.opencodex', 'config.json'), 'utf8'));
  const key = config.providers?.['opencode-go']?.apiKey;
  if (typeof key !== 'string' || !key.trim()) throw new Error('OpenCode Go credential is unavailable');
  return key.trim();
}

export async function goComplete(body, { signal, fetchImpl = fetch, key = goKey } = {}) {
  const response = await fetchImpl('https://opencode.ai/inference/go/v1/chat/completions', {
    method: 'POST', signal,
    headers: { Authorization: `Bearer ${await key()}`, 'Content-Type': 'application/json',
      'User-Agent': 'newswire-agent/1.0', 'x-opencode-session': randomUUID() },
    body: JSON.stringify({ ...body, model: goModel, thinking: { type: 'disabled' }, stream: false }),
  });
  if (!response.ok) throw new Error(`OpenCode Go HTTP ${response.status}`);
  const result = await response.json();
  const choice = result.choices?.[0];
  if (result.model !== goModel || !Array.isArray(result.choices) || result.choices.length !== 1 || !choice?.message
      || choice.finish_reason === 'length'
      || !(choice.message.content?.trim() || choice.message.tool_calls?.length)) throw new Error('OpenCode Go returned an incomplete answer');
  return { model: goModel, provider: 'opencode-go', billing: 'subscription', choices: result.choices, usage: result.usage };
}

export async function complete(body, { signal, timeout = 75000, free = freeComplete, go = goComplete } = {}) {
  if (body.model && body.model !== freeModel) throw new Error('Only the configured DeepSeek route is enabled');
  const deadline = AbortSignal.timeout(timeout);
  const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
  try {
    return await free(body, { signal: combined, timeout: Math.min(12000, timeout) });
  } catch {
    combined.throwIfAborted();
    return go(body, { signal: combined });
  }
}
