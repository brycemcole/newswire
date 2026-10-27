import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const model = 'deepseek-flash';
const endpoint = 'https://api.deepseek.com/chat/completions';

let cached;
export async function key() {
  if (cached) return cached;
  let value = process.env.DEEPSEEK_API_KEY?.trim() ?? '';
  for (const path of [process.env.DEEPSEEK_API_KEY_FILE, join(homedir(), '.config', 'newswire', 'deepseek-key'), join(homedir(), '.kalshi', 'deepseek.key')]) {
    if (value || !path) continue;
    value = (await readFile(path, 'utf8').catch(() => '')).trim();
  }
  if (!value) throw new Error('DEEPSEEK_API_KEY or a deepseek-key file is required');
  return (cached = value);
}

export async function complete(body, { signal, timeout = 75000, fetchImpl = fetch, apiKey = key } = {}) {
  const deadline = AbortSignal.timeout(timeout);
  const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
  const request = JSON.stringify({ model, ...body, thinking: { type: 'disabled' }, stream: false }, (_key, value) => typeof value === 'string' ? value.toWellFormed() : value);
  let failure;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt) await new Promise(resolve => setTimeout(resolve, 1500 * attempt));
    combined.throwIfAborted();
    let response;
    try {
      response = await fetchImpl(endpoint, { method: 'POST', signal: combined, body: request,
        headers: { Authorization: `Bearer ${await apiKey()}`, 'Content-Type': 'application/json' } });
    } catch (error) {
      combined.throwIfAborted();
      failure = error;
      continue;
    }
    if (response.status === 429 || response.status >= 500) { failure = new Error(`DeepSeek HTTP ${response.status}`); continue; }
    if (!response.ok) throw new Error(`DeepSeek HTTP ${response.status}`);
    const result = await response.json();
    const choice = result.choices?.[0];
    if (!choice?.message || result.choices.length !== 1 || choice.finish_reason === 'length' || !(choice.message.content?.trim() || choice.message.tool_calls?.length)) throw new Error('DeepSeek returned an incomplete answer');
    return { model: result.model ?? model, provider: 'deepseek', choices: result.choices, usage: { prompt_tokens: result.usage?.prompt_tokens ?? 0, completion_tokens: result.usage?.completion_tokens ?? 0 } };
  }
  throw failure ?? new Error('DeepSeek request failed');
}
