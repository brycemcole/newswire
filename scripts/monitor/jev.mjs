import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';

// Free and paid Jev 1.13 are the same model, so cached verdicts stay valid across the fallback.
export const classifierIdentity = 'zen:jev-1.13';
const endpoint = 'https://opencode.ai/zen/v1/systemone';
const freeModel = 'jev-1.13-free';
const paidModel = 'jev-1.13';
const cooldownFile = join(homedir(), '.config', 'newswire', 'zen-cooldown.json');
let queue = Promise.resolve();
let nextRequest = 0;
let cooldowns;
const usage = { [freeModel]: 0, [paidModel]: 0 };

export const classifierUsage = () => ({ ...usage });

export function retryTime(value, now = Date.now()) {
  const seconds = Number(value);
  const parsed = value && Number.isFinite(seconds) ? now + Math.max(0, seconds) * 1000 : Date.parse(value ?? '');
  return Number.isFinite(parsed) && parsed > now ? parsed : now + 60000;
}

let cached;
async function key() {
  if (cached) return cached;
  const value = (process.env.NEWSWIRE_ZEN_API_KEY ?? await readFile(join(homedir(), '.config', 'newswire', 'zen-key'), 'utf8').catch(() => '')).trim();
  if (!value) throw new Error('NEWSWIRE_ZEN_API_KEY or protected zen-key file is required');
  return (cached = value);
}

async function loadCooldowns() {
  if (cooldowns) return cooldowns;
  const saved = JSON.parse(await readFile(cooldownFile, 'utf8').catch(() => '{}'));
  // Older files held a single free-model deadline at the top level.
  cooldowns = saved.until ? { [saved.model ?? freeModel]: Number(saved.until) || 0 } : Object.fromEntries(Object.entries(saved).map(([model, until]) => [model, Number(until) || 0]));
  return cooldowns;
}

async function coolDown(model, until) {
  cooldowns[model] = until;
  await mkdir(join(homedir(), '.config', 'newswire'), { recursive: true, mode: 0o700 });
  const temporary = `${cooldownFile}.${process.pid}.tmp`;
  await writeFile(temporary, JSON.stringify(cooldowns) + '\n', { mode: 0o600 });
  await rename(temporary, cooldownFile);
}

async function call(model, state, questions, timeout) {
  if (Date.now() < (cooldowns[model] ?? 0)) throw new Error(`zen ${model} cooling down until ${new Date(cooldowns[model]).toISOString()}`);
  const delay = nextRequest - Date.now();
  if (delay > 0) await new Promise(resolve => setTimeout(resolve, delay));
  nextRequest = Date.now() + 1000;
  usage[model] += 1;
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${await key()}`, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ model, questions: Object.fromEntries(Object.entries(questions).map(([name, question]) => [name, { type: 'choice', ...question }])), state }),
    signal: AbortSignal.timeout(timeout),
  });
  if (!response.ok) {
    if (response.status === 429) {
      const until = retryTime(response.headers.get('Retry-After'));
      await coolDown(model, until);
      throw new Error(`zen ${model} 429; retry after ${new Date(until).toISOString()}`);
    }
    const payload = await response.json().catch(() => ({}));
    const code = /^[\w.:-]{1,128}$/.test(payload.detail?.error_type ?? '') ? `; code: ${payload.detail.error_type}` : '';
    throw new Error(`zen ${model} ${response.status}${code}`);
  }
  return (await response.json()).answers ?? {};
}

async function request(state, questions, { timeout = 10000 } = {}) {
  await loadCooldowns();
  let answers;
  try {
    answers = await call(freeModel, state, questions, timeout);
  } catch (freeError) {
    try {
      answers = await call(paidModel, state, questions, timeout);
    } catch (paidError) {
      throw new Error(`${freeError.message}; paid fallback: ${paidError.message}`);
    }
  }
  for (const name of Object.keys(questions)) {
    if (!Object.hasOwn(questions[name].criteria, answers[name]?.choice ?? '') || !Number.isFinite(answers[name].confidence) || answers[name].confidence < 0 || answers[name].confidence > 1) throw new Error(`jev response invalid ${name} answer`);
  }
  return answers;
}

export function ask(state, questions, options) {
  const result = queue.then(() => request(state, questions, options));
  queue = result.catch(() => {});
  return result;
}
