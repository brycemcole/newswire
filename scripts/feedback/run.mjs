import { execFile } from 'node:child_process';
import { createSign } from 'node:crypto';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { connect } from 'node:http2';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { credentials, devices, send } from '../monitor/apns.mjs';
import { token } from '../monitor/publish.mjs';

const run = promisify(execFile);
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const config = join(homedir(), '.config', 'newswire');
const repo = process.env.NEWSWIRE_FIX_REPO ?? join(homedir(), 'feedback', 'newswire');
const scratch = join(homedir(), '.cache', 'newswire-feedback');
const slug = process.env.NEWSWIRE_GITHUB_REPO ?? 'brycemcole/newswire';
const agent = process.env.NEWSWIRE_FIX_AGENT ?? 'claude';
const hosts = { sandbox: 'https://api.sandbox.push.apple.com', production: 'https://api.push.apple.com' };

async function api(path, init = {}) {
  const response = await fetch(new URL(path, origin), {
    ...init,
    headers: { Authorization: `Bearer ${await token()}`, ...(init.body ? { 'Content-Type': 'application/json' } : {}), ...init.headers },
    signal: AbortSignal.timeout(30000),
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) throw new Error(`${init.method ?? 'GET'} ${path} -> ${response.status} ${body?.error?.message ?? ''}`.trim());
  return body;
}

const update = (id, data) => api(`/v1/feedback/${id}`, { method: 'POST', body: JSON.stringify(data) });

export function prompt(report, images) {
  const kind = report.kind === 'feature' ? 'feature request' : 'bug report';
  const context = Object.entries(report.context ?? {}).map(([key, value]) => `- ${key}: ${value}`).join('\n');
  return [
    `Bryce sent this ${kind} from the Newswire iPhone app by shaking the phone.`,
    '',
    'Report:',
    report.note.split('\n').map(line => `> ${line}`).join('\n'),
    '',
    'Device context:',
    context || '- none',
    '',
    images.length ? `Screenshots (read each one before deciding what to change):\n${images.map(path => `- ${path}`).join('\n')}` : 'No screenshots were attached.',
    '',
    report.kind === 'feature'
      ? 'Implement the requested feature in this repository, following AGENTS.md and the conventions of the surrounding code. Keep the change focused.'
      : 'Find the cause of the reported problem in this repository and fix it, following AGENTS.md. Reproduce or pin down the cause before changing code, and add or extend a regression test where the code is testable.',
    'This machine is Linux: you cannot build or run the iOS app. Run the backend and script tests that cover what you change. If you change SwiftUI, say plainly that it is uncompiled and unseen.',
    'Do not commit, push, or open a pull request; that happens after you finish. Do not touch secrets.',
    'End with a short plain-text summary: what you changed, why, what you verified, and anything left unverified.',
  ].join('\n');
}

export function prBody(report, summary) {
  const context = Object.entries(report.context ?? {}).map(([key, value]) => `${key}: ${value}`).join(' · ');
  return [
    `## ${report.kind === 'feature' ? 'Feature request' : 'Bug report'} from the app`,
    '',
    report.note.split('\n').map(line => `> ${line}`).join('\n'),
    '',
    context && `<sub>${context} · ${report.image_count} screenshot${report.image_count === 1 ? '' : 's'} · report ${report.id}</sub>`,
    '',
    `## What ${agent === 'codex' ? 'Codex' : 'Claude Code'} did`,
    '',
    summary.trim() || '(no summary)',
    '',
    'Opened automatically by `scripts/feedback/run.mjs`. Review before merging; iOS changes are uncompiled until CI runs.',
  ].filter(line => line !== '').join('\n\n').replace(/\n{3,}/g, '\n\n');
}

async function git(cwd, ...args) {
  return (await run('git', args, { cwd, maxBuffer: 16 << 20 })).stdout.trim();
}

async function github() {
  return (process.env.NEWSWIRE_GITHUB_TOKEN ?? await readFile(join(config, 'github-token'), 'utf8')).trim();
}

async function ensureRepo(auth) {
  const header = `http.https://github.com/.extraheader=Authorization: Basic ${Buffer.from(`x-access-token:${auth}`).toString('base64')}`;
  await mkdir(join(repo, '..'), { recursive: true });
  try { await git(repo, 'rev-parse', '--git-dir'); }
  catch { await run('git', ['-c', header, 'clone', `https://github.com/${slug}.git`, repo], { maxBuffer: 16 << 20 }); }
  await git(repo, '-c', header, 'fetch', '--prune', 'origin', 'main');
  await git(repo, 'worktree', 'prune');
  return header;
}

async function runAgent(cwd, text, images) {
  const options = { cwd, timeout: 30 * 60000, maxBuffer: 64 << 20, env: { ...process.env, CI: '1' } };
  if (agent === 'codex') {
    const out = join(scratch, `codex-${Date.now()}.txt`);
    await run('codex', ['exec', '--full-auto', '--skip-git-repo-check', '--output-last-message', out, ...images.flatMap(path => ['-i', path]), text], options);
    return readFile(out, 'utf8').catch(() => '');
  }
  const { stdout } = await run('claude', ['-p', text, '--output-format', 'json', '--permission-mode', 'acceptEdits', '--add-dir', join(scratch),
    '--allowedTools', 'Read,Edit,Write,Glob,Grep,Bash(node:*),Bash(npm:*),Bash(npx:*),Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(rg:*),Bash(ls:*)'], options);
  return JSON.parse(stdout).result ?? '';
}

async function notify(report, title, body) {
  try {
    const jwt = await credentials();
    const all = await devices(await token());
    const targets = report.device ? all.filter(device => device.token === report.device) : all;
    for (const [environment, host] of Object.entries(hosts)) {
      const group = targets.filter(device => device.environment === environment);
      if (!group.length) continue;
      const client = connect(host);
      await Promise.all(group.map(device => send(client, jwt, device, { aps: { alert: { title, body }, sound: 'default' } })));
      client.close();
    }
  } catch (error) {
    console.error(`notify failed: ${error.message}`);
  }
}

async function fix(summary) {
  const report = (await api(`/v1/feedback/${summary.id}`)).feedback;
  const short = report.id.slice(0, 8);
  const branch = `feedback/${report.kind}-${short}`;
  const tree = join(repo, '..', `wt-${short}`);
  const shots = join(scratch, short);
  await mkdir(shots, { recursive: true });
  const images = [];
  for (const [index, data] of report.images.entries()) {
    const path = join(shots, `${index + 1}.jpg`);
    await writeFile(path, Buffer.from(data, 'base64'));
    images.push(path);
  }
  const auth = await github();
  const header = await ensureRepo(auth);
  await rm(tree, { recursive: true, force: true });
  await git(repo, 'worktree', 'add', '-B', branch, tree, 'origin/main');
  try {
    const result = await runAgent(tree, prompt(report, images), images);
    await git(tree, 'add', '-A');
    if (!await git(tree, 'status', '--porcelain')) {
      await update(report.id, { status: 'failed', from: 'working', result: result.slice(0, 4000) || 'The agent made no changes.' });
      await notify(report, 'Report needs you', 'The agent made no changes. See the report result for why.');
      return;
    }
    const subject = (report.kind === 'feature' ? 'Add: ' : 'Fix: ') + report.note.split('\n')[0].slice(0, 60);
    await git(tree, '-c', 'user.name=Newswire Feedback', '-c', 'user.email=feedback@newswire.invalid', 'commit', '-m', `${subject}\n\nFrom shake report ${report.id}.`);
    await git(tree, '-c', header, 'push', '-f', '-u', 'origin', branch);
    const response = await fetch(`https://api.github.com/repos/${slug}/pulls`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${auth}`, Accept: 'application/vnd.github+json', 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: subject, head: branch, base: 'main', draft: true, body: prBody(report, result) }),
      signal: AbortSignal.timeout(30000),
    });
    const pr = await response.json();
    if (!response.ok) throw new Error(`GitHub PR ${response.status}: ${pr.message}`);
    await update(report.id, { status: 'done', from: 'working', pr_url: pr.html_url, result: result.slice(0, 4000) });
    await notify(report, `Draft PR #${pr.number} ready`, subject);
    console.log(JSON.stringify({ id: report.id, pr: pr.html_url }));
  } finally {
    await git(repo, 'worktree', 'remove', '--force', tree).catch(() => {});
    await rm(shots, { recursive: true, force: true });
  }
}

async function ascToken(asc) {
  const key = await readFile(join(config, 'asc-key.p8'), 'utf8');
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${encode({ alg: 'ES256', kid: asc.key_id, typ: 'JWT' })}.${encode({ iss: asc.issuer_id, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' })}`;
  return `${unsigned}.${createSign('SHA256').update(unsigned).sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

// TestFlight's own screenshot feedback, when an App Store Connect key is installed, joins the same queue.
async function importTestFlight() {
  const asc = JSON.parse(await readFile(join(config, 'asc.json'), 'utf8').catch(() => 'null'));
  if (!asc?.key_id || !asc?.issuer_id) return;
  const stateFile = join(config, 'feedback-testflight.json');
  const seen = new Set(JSON.parse(await readFile(stateFile, 'utf8').catch(() => '[]')));
  const jwt = await ascToken(asc);
  const response = await fetch(`https://api.appstoreconnect.apple.com/v1/apps/${asc.app_id ?? '6817506877'}/betaFeedbackScreenshotSubmissions?sort=-createdDate&limit=20`, { headers: { Authorization: `Bearer ${jwt}` }, signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`TestFlight feedback ${response.status}`);
  for (const item of (await response.json()).data ?? []) {
    if (seen.has(item.id)) continue;
    const attributes = item.attributes ?? {};
    const images = [];
    for (const shot of (attributes.screenshots ?? []).slice(0, 4)) {
      const image = await fetch(shot.url, { signal: AbortSignal.timeout(30000) }).catch(() => null);
      if (image?.ok && image.headers.get('content-type')?.includes('jpeg')) images.push(Buffer.from(await image.arrayBuffer()).toString('base64'));
    }
    await api('/v1/feedback', { method: 'POST', body: JSON.stringify({
      kind: 'bug',
      note: attributes.comment?.trim() || '(TestFlight screenshot with no comment)',
      images: images.filter(i => i.length <= 1_400_000),
      context: { source: 'testflight', model: attributes.deviceModel ?? '', os: attributes.osVersion ?? '', reported_at: attributes.createdDate ?? '', testflight_id: item.id },
    }) });
    seen.add(item.id);
  }
  await writeFile(stateFile, JSON.stringify([...seen].slice(-500)));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await mkdir(scratch, { recursive: true });
  await importTestFlight().catch(error => console.error(`testflight import failed: ${error.message}`));
  const pending = (await api('/v1/feedback')).feedback;
  for (const report of pending.slice(0, Number(process.env.NEWSWIRE_FIX_LIMIT ?? 1))) {
    try { await update(report.id, { status: 'working', from: 'new' }); } catch { continue; }
    try { await fix(report); }
    catch (error) {
      console.error(`report ${report.id} failed: ${error.message}`);
      await update(report.id, { status: 'failed', from: 'working', result: error.message.slice(0, 4000) }).catch(() => {});
      await notify(report, 'Report could not be fixed', error.message.slice(0, 150));
    }
  }
}
