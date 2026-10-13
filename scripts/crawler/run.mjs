#!/usr/bin/env node
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createCrawler, loadConfig, playwrightFactory } from './crawler.mjs';

export function parseArgs(argv) {
  const options = { once: false, dryRun: false, scroll: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--once') options.once = true;
    else if (arg === '--dry-run') options.dryRun = true;
    else if (arg === '--scroll') options.scroll = true;
    else if (/^--(?:questions-file|state-dir|report-file|config)=/.test(arg)) {
      const [key, ...rest] = arg.slice(2).split('='); options[key.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = rest.join('=');
    } else if (['--questions-file', '--state-dir', '--report-file', '--config'].includes(arg)) {
      if (!argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error(`${arg} requires a path`);
      options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[++i];
    } else throw new Error(`Unknown option: ${arg}`);
  }
  if (!options.once) throw new Error('Only bounded --once mode is supported');
  return options;
}

export async function main(argv = process.argv.slice(2), io = console, dependencies = {}) {
  const args = parseArgs(argv);
  const config = await loadConfig(args.config);
  if (args.questionsFile) config.questionsFile = resolve(args.questionsFile);
  if (args.reportFile) config.reportFile = resolve(args.reportFile);
  const stateDir = args.stateDir ? resolve(args.stateDir) : undefined;
  const stateFile = stateDir ? join(stateDir, 'crawler-state.json') : undefined;
  let browserFactory = null, browserStatus = args.scroll ? 'unavailable' : 'disabled', browserReason = null;
  if (args.scroll) {
    try { await import('playwright'); browserFactory = playwrightFactory; browserStatus = 'ready'; }
    catch (error) { browserReason = `Playwright is unavailable: ${error.code ?? error.message}`; }
  }
  const crawler = createCrawler({ config, ...(stateFile ? { stateFile } : {}), browserFactory, ...dependencies });
  const result = await crawler.runOnce({ dryRun: args.dryRun, scroll: args.scroll && Boolean(browserFactory) });
  result.browser_status = browserStatus;
  if (browserReason) result.browser_reason = browserReason;
  const reportFile = config.reportFile;
  if (reportFile && !args.dryRun) {
    await mkdir(dirname(reportFile), { recursive: true, mode: 0o700 });
    const { state: _state, ...report } = result;
    await writeFile(reportFile, JSON.stringify({ ...report, stories: result.stories.map(({ id, url, title, published_at, publication_status, observed_at, provenance, search_role, event_id, query, content_hash }) => ({ id, url, title, published_at, publication_status, observed_at, provenance, search_role, event_id, query, content_hash })) }, null, 2) + '\n', { mode: 0o600 });
  }
  io.log(JSON.stringify({ processed: result.processed, findings: result.findings, unique_findings: result.unique_findings,
    questions_attempted: result.questions_attempted, queued: result.queued, health: result.health, browser_status: result.browser_status,
    ...(result.browser_reason ? { browser_reason: result.browser_reason } : {}), failures: result.failures }, null, 2));
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => { console.error(`crawler: ${error.message}`); process.exitCode = 1; });
}
