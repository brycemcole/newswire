import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

// OpenCode Go is the subscription plan; Zen is pay-as-you-go on the same OpenCode account.
const providers = {
  go: 'https://opencode.ai/inference/go/v1/chat/completions',
  zen: 'https://opencode.ai/inference/v1/chat/completions',
};
const provider = process.env.NEWSWIRE_AGENT_PROVIDER ?? 'go';
if (!providers[provider]) throw new Error(`NEWSWIRE_AGENT_PROVIDER must be one of ${Object.keys(providers).join(', ')}`);
export const userAgent = 'newswire-research-agent/1.0';
const usage = { requests: 0, prompt_tokens: 0, completion_tokens: 0 };
export const agentUsage = () => ({ provider, ...usage });

let cached;
async function key() {
  if (cached) return cached;
  const config = join(homedir(), '.config', 'newswire');
  const value = process.env.NEWSWIRE_OPENCODE_KEY ?? await readFile(join(config, 'opencode-key'), 'utf8').catch(() => '') ?? '';
  // The Jev classifier already authenticates with an OpenCode console key.
  cached = (value.trim() || (await readFile(join(config, 'zen-key'), 'utf8').catch(() => '')).trim());
  if (!cached) throw new Error('NEWSWIRE_OPENCODE_KEY, opencode-key or zen-key is required');
  return cached;
}

async function complete(body, session, attempt = 0) {
  let response;
  try {
    response = await fetch(providers[provider], { method: 'POST', signal: AbortSignal.timeout(120000), body: JSON.stringify(body),
      headers: { Authorization: `Bearer ${await key()}`, 'Content-Type': 'application/json', Accept: 'application/json', 'User-Agent': userAgent, 'x-opencode-session': session } });
  } catch (error) {
    if (attempt < 2) { await new Promise(resolve => setTimeout(resolve, 2000 * 2 ** attempt)); return complete(body, session, attempt + 1); }
    throw error;
  }
  const payload = await response.json().catch(() => ({}));
  if ((response.status === 429 || response.status >= 500) && attempt < 2) {
    await new Promise(resolve => setTimeout(resolve, 3000 * 2 ** attempt));
    return complete(body, session, attempt + 1);
  }
  if (!response.ok) throw new Error(`${provider} ${body.model} HTTP ${response.status}${payload.error?.type ? ` ${payload.error.type}` : ''}`);
  usage.requests += 1;
  usage.prompt_tokens += payload.usage?.prompt_tokens ?? 0;
  usage.completion_tokens += payload.usage?.completion_tokens ?? 0;
  const choice = payload.choices?.[0];
  if (!choice?.message) throw new Error(`${provider} ${body.model} returned no message`);
  return choice;
}

export function parseJSON(text) {
  const raw = String(text ?? '').replace(/^\s*```(?:json)?/i, '').replace(/```\s*$/, '');
  const start = raw.indexOf('{'), end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) throw new Error('Answer contained no JSON object');
  return JSON.parse(raw.slice(start, end + 1));
}

/** Runs a tool-calling conversation until the model returns a JSON object or the step budget runs out. */
export async function runAgent({ model, system, prompt, tools, maxSteps = 8, maxTokens = 8000, temperature = 0.2 }) {
  const session = randomUUID();
  const definitions = tools.map(tool => ({ type: 'function', function: { name: tool.name, description: tool.description, parameters: tool.parameters } }));
  const byName = new Map(tools.map(tool => [tool.name, tool]));
  const messages = [{ role: 'system', content: system }, { role: 'user', content: prompt }];
  const trace = [];
  for (let step = 0; step <= maxSteps; step++) {
    const last = step === maxSteps;
    if (last) messages.push({ role: 'user', content: 'The research budget is spent. Reply now with only the final JSON object.' });
    const choice = await complete({ model, messages, tools: definitions, tool_choice: last ? 'none' : 'auto', max_tokens: maxTokens, temperature }, session);
    const message = Object.fromEntries(Object.entries(choice.message).filter(([, value]) => value !== null && value !== undefined));
    messages.push(message);
    const calls = message.tool_calls ?? [];
    if (!calls.length) {
      if (choice.finish_reason === 'length') throw new Error(`${model} answer was truncated at ${maxTokens} tokens`);
      try { return { result: parseJSON(message.content), trace, steps: step + 1 }; } catch (error) {
        if (last) throw error;
        messages.push({ role: 'user', content: `That was not valid JSON (${error.message}). Reply with only the JSON object.` });
        continue;
      }
    }
    const outputs = await Promise.all(calls.map(async call => {
      const tool = byName.get(call.function?.name);
      let output;
      try {
        if (!tool) throw new Error(`Unknown tool ${call.function?.name}`);
        const args = call.function.arguments ? JSON.parse(call.function.arguments) : {};
        output = await tool.run(args);
      } catch (error) { output = `Error: ${error.message}`; }
      const text = typeof output === 'string' ? output : JSON.stringify(output);
      trace.push({ tool: call.function?.name, arguments: String(call.function?.arguments ?? '').slice(0, 300), ok: !text.startsWith('Error:') });
      return { role: 'tool', tool_call_id: call.id, content: text.slice(0, 7000) };
    }));
    messages.push(...outputs);
  }
  throw new Error(`${model} did not finish`);
}
