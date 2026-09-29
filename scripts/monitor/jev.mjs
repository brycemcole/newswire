import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';

const origin = process.env.TYPESAFE_BASE_URL ?? 'https://api.typesafe.ai';
const model = process.env.TYPESAFE_DEFAULT_MODEL ?? 'jev-latest';

let cached;
async function key() {
  if (cached) return cached;
  if (process.env.TYPESAFE_API_KEY) return (cached = process.env.TYPESAFE_API_KEY.trim());
  for (const file of [join(homedir(), '.config', 'newswire', 'typesafe-key'), join(homedir(), 'Desktop', 'typesafe-key.md')]) {
    const value = (await readFile(file, 'utf8').catch(() => '')).trim();
    if (value && value !== 'PASTE_KEY_HERE') return (cached = value);
  }
  throw new Error('TYPESAFE_API_KEY is missing and no key file is filled in');
}

export async function ask(state, questions, { timeout = 10000 } = {}) {
  const response = await fetch(`${origin}/v1/systemone`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${await key()}`, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ model, questions: Object.fromEntries(Object.entries(questions).map(([name, question]) => [name, { type: 'choice', ...question }])), state }),
    signal: AbortSignal.timeout(timeout),
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    const code = /^[\w.:-]{1,128}$/.test(payload.detail?.error_type ?? '') ? `; code: ${payload.detail.error_type}` : '';
    throw new Error(`jev ${response.status}${code}`);
  }
  const answers = (await response.json()).answers ?? {};
  for (const name of Object.keys(questions)) {
    if (typeof answers[name]?.choice !== 'string' || !Number.isFinite(answers[name].confidence)) throw new Error(`jev response missing ${name} answer`);
  }
  return answers;
}
