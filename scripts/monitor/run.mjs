import { createHash } from 'node:crypto';
import { notify, wake } from './apns.mjs';
import { syncCalendar } from './calendar.mjs';
import { publish } from './publish.mjs';
import { classifierIdentity, classifierUsage } from './jev.mjs';
import { classifyImpacts } from './impacts.mjs';
import { load, save, statePath } from './state.mjs';
import * as crypto from './rules/crypto.mjs';
import * as congress from './rules/congress.mjs';
import * as contracts from './rules/contracts.mjs';
import * as disasters from './rules/disasters.mjs';
import * as earnings from './rules/earnings.mjs';
import * as equities from './rules/equities.mjs';
import * as fed from './rules/fed.mjs';
import * as fiscal from './rules/fiscal.mjs';
import * as global from './rules/global.mjs';
import * as headlines from './rules/headlines.mjs';
import * as household from './rules/household.mjs';
import * as infrastructure from './rules/infrastructure.mjs';
import * as insiders from './rules/insiders.mjs';
import * as macro from './rules/macro.mjs';
import * as markets from './rules/markets.mjs';
import * as policy from './rules/policy.mjs';
import * as rates from './rules/rates.mjs';
import * as sectors from './rules/sectors.mjs';
import * as shipping from './rules/shipping.mjs';
import * as trending from './rules/trending.mjs';
import * as treasury from './rules/treasury.mjs';
import * as volatility from './rules/volatility.mjs';

const rules = [markets, global, sectors, volatility, rates, equities, earnings, insiders, crypto, macro, fiscal, fed, treasury, household, congress, contracts, shipping, disasters, policy, infrastructure, trending, headlines];
const cooldown = { markets: 6, volatility: 12, rates: 12, equities: 12, crypto: 12, sectors: 6 };
const dryRun = process.argv.includes('--dry-run');
const seed = process.argv.includes('--seed');
const only = process.argv.find(argument => argument.startsWith('--only='))?.slice(7).split(',');
const limit = Number(process.argv.find(argument => argument.startsWith('--limit='))?.slice(8) ?? 8);
const lookbackArg = process.argv.find(argument => argument.startsWith('--backfill-hours='));
const lookbackHours = lookbackArg === undefined ? undefined : Number(lookbackArg.slice(17));
const noNotify = process.argv.includes('--no-notify') || lookbackArg !== undefined;
if (lookbackArg !== undefined && (!Number.isFinite(lookbackHours) || lookbackHours < 1 || lookbackHours > 168 || only?.length !== 1 || only[0] !== 'headlines')) throw new Error('--backfill-hours=1..168 requires --only=headlines');

function externalId(key) {
  return `monitor:${createHash('sha256').update(key).digest('hex').slice(0, 32)}`;
}

const calendarSync = dryRun || seed || only ? Promise.resolve([]) : syncCalendar().catch(error => ["calendar: " + error.message]);
const selected = only ? rules.filter(rule => only.includes(rule.id)) : rules;
const settled = await Promise.allSettled(selected.map(rule => rule.id === 'headlines' ? rule.run({ lookbackHours }) : rule.run()));
const state = await load();
const failures = [];
const candidates = [];

settled.forEach((entry, index) => {
  const rule = selected[index];
  if (entry.status === 'rejected') {
    failures.push(`${rule.id}: ${entry.reason?.message ?? entry.reason}`);
    return;
  }
  failures.push(...(entry.value.failures ?? []));
  for (const event of entry.value.events ?? []) candidates.push({ ...event, rule: rule.id });
});

const now = Date.now();
const fresh = candidates.filter(event => {
  const previous = state[event.key];
  if (!previous) return true;
  const hours = cooldown[event.rule];
  return hours ? now - Date.parse(previous.at) >= hours * 3600000 : false;
});

const rank = { breaking: 0, urgent: 1, normal: 2 };
fresh.sort((a, b) => rank[a.priority] - rank[b.priority]);
const batch = fresh.slice(0, limit);

const published = [];
for (const event of seed ? [] : batch) {
  const story = {
    external_id: externalId(event.key),
    title: event.title.slice(0, 300),
    summary: event.summary.slice(0, 2000),
    body: (event.body ?? '').slice(0, 20000),
    source: event.source.slice(0, 100),
    url: event.url,
    image_url: event.image_url ?? '',
    published_at: event.published_at ?? new Date().toISOString(),
    category: event.category,
    priority: event.priority,
    tickers: event.tickers ?? [],
    tags: [...new Set(event.tags ?? [])].slice(0, 20),
    agent: 'newswire-monitor',
  };
  if (dryRun) {
    published.push({ ...event, story, result: 'dry-run' });
    continue;
  }
  try {
    const result = await publish(story);
    state[event.key] = { at: new Date().toISOString(), rule: event.rule };
    published.push({ ...event, story: { ...story, id: result.id }, result: result.duplicate ? 'duplicate' : 'new' });
  } catch (error) {
    failures.push(`publish ${event.key}: ${error.message}`);
  }
}

const alerts = noNotify ? [] : published.filter(entry => entry.result === 'new' && ['breaking', 'urgent'].includes(entry.story.priority)).map(entry => entry.story);
failures.push(...await notify(alerts).catch(error => [`notify: ${error.message}`]));
if (!noNotify && !alerts.length && published.some(entry => entry.result === 'new')) failures.push(...await wake().catch(error => [`wake: ${error.message}`]));

if (seed) for (const event of candidates) state[event.key] ??= { at: new Date().toISOString(), rule: event.rule };
if (!dryRun) await save(state);

failures.push(...await calendarSync);

// Market-impact reads run after publishing so they never delay a story.
const impacts = dryRun || seed || lookbackArg !== undefined || (only && !only.includes('headlines')) ? null
  : await classifyImpacts().catch(error => ({ failures: [`impacts: ${error.message}`] }));
failures.push(...(impacts?.failures ?? []));

const report = {
  checked: selected.map(rule => rule.id),
  mode: seed ? 'seed' : dryRun ? 'dry-run' : 'publish',
  classifier: classifierIdentity,
  classifier_calls: classifierUsage(),
  impacts: impacts && { calls: impacts.calls, moving: impacts.moving, posted: impacts.posted, backlog: impacts.backlog },
  backfill_hours: lookbackHours ?? null,
  notifications: noNotify ? 'suppressed' : 'normal',
  candidates: candidates.length,
  fresh: fresh.length,
  published: published.filter(entry => entry.result === 'new').length,
  duplicates: published.filter(entry => entry.result === 'duplicate').length,
  suppressed: candidates.length - fresh.length,
  failures,
  state: dryRun ? 'not written' : statePath(),
  stories: published.map(entry => ({ rule: entry.rule, priority: entry.priority, result: entry.result, title: entry.title })),
};
console.log(JSON.stringify(report, null, 2));
if (failures.length && !published.length) process.exitCode = 1;
