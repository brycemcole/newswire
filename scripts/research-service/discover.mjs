import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { token } from '../monitor/publish.mjs';
import { classifyImpacts } from '../monitor/impacts.mjs';

const state = join(homedir(), '.config', 'newswire', 'crawler');
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
if (new URL(origin).protocol !== 'https:') throw new Error('Research service requires HTTPS');
await mkdir(state, { recursive: true, mode: 0o700 });
const questions = new Map();
const failures = [];
try {
  const generated = await fetch(new URL('/v1/research/questions', origin), { method: 'POST',
    headers: { Authorization: `Bearer ${await token()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ symbol: 'SPY' }), signal: AbortSignal.timeout(20000) });
  if (!generated.ok) failures.push(`Question generation HTTP ${generated.status}`);
} catch (error) { failures.push(`Question generation: ${error.message}`); }
for (const symbol of ['SPY', 'QQQ']) {
  try {
    const response = await fetch(new URL(`/v1/research?symbol=${symbol}`, origin), {
      headers: { Authorization: `Bearer ${await token()}` }, signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) throw new Error(`research HTTP ${response.status}`);
    for (const question of (await response.json()).questions ?? []) {
      if (['open', 'queued'].includes(question.status)) questions.set(question.id, question);
    }
  } catch (error) { failures.push(`${symbol}: ${error.message}`); }
}
const questionFile = join(state, 'questions.json');
const temporary = `${questionFile}.${process.pid}.tmp`;
await writeFile(temporary, JSON.stringify([...questions.values()].slice(0, 20)), { mode: 0o600 });
await rename(temporary, questionFile);
const reportFile = join(state, 'latest-report.json');
const child = spawn(process.execPath, [fileURLToPath(new URL('../crawler/run.mjs', import.meta.url)), '--once', '--scroll',
  `--questions-file=${questionFile}`, `--state-dir=${state}`, `--report-file=${reportFile}`], { stdio: 'inherit' });
const result = await new Promise((resolve, reject) => {
  child.once('error', reject);
  child.once('exit', (code, signal) => resolve({ code, signal }));
});
if (result.code === 0) {
  const raw = JSON.parse(await readFile(reportFile, 'utf8'));
  const report = { ...raw, stories: (raw.stories ?? []).slice(-60), research_questions: (raw.research_questions ?? []).slice(-60) };
  const posted = await fetch(new URL('/v1/research/discovery', origin), { method: 'POST',
    headers: { Authorization: `Bearer ${await token()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(report), signal: AbortSignal.timeout(20000) });
  if (!posted.ok) { failures.push(`Discovery report HTTP ${posted.status}`); process.exitCode = 1; }
  const impacts = await classifyImpacts({ limit: 25 }).catch(error => ({ failures: [error.message] }));
  failures.push(...(impacts.failures ?? []));
  console.log(JSON.stringify({ crawler_impacts: impacts }));
}
console.log(JSON.stringify({ questions: questions.size, failures, ...result }));
if (result.code !== 0 || result.signal || failures.length) process.exitCode = 1;
