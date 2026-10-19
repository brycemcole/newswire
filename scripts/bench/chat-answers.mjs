#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { token } from '../monitor/publish.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const swiftPath = 'ios/Sources/StockResearch.swift';

export const questions = [
  { id: 'peers', q: 'How does Visa compare to its payments peers on growth and margins?', table: true },
  { id: 'chips', q: 'Compare Nvidia, AMD and Broadcom year to date.', table: true },
  { id: 'banks', q: 'How did JPMorgan, Bank of America and Wells Fargo do in their latest quarter?', table: true },
  { id: 'today', q: 'Why are markets moving today?', stories: true },
  { id: 'fed', q: 'What is the market pricing for the next Fed meeting?', stories: true },
  { id: 'megacap', q: 'How are Apple, Microsoft, Alphabet and Amazon valued versus their growth?', table: true },
  { id: 'cpi', q: 'What did the latest CPI report show versus forecasts?' },
  { id: 'yields', q: 'How have the 2-year and 10-year Treasury yields changed over the past month?' },
  { id: 'wire', q: 'What has Newswire reported about AI companies this week?', stories: true },
];

function swiftString(source, name) {
  const match = source.match(new RegExp(`let ${name} = """\\n([\\s\\S]*?)\\n\\s*"""`));
  if (!match) throw new Error(`Missing ${name} prompt in ${swiftPath}`);
  return match[1].split('\n').map(line => line.trim()).join('\n').replaceAll('\\"', '"');
}

export function prompt(source, today = new Date().toISOString().slice(0, 10)) {
  return swiftString(source, 'marketInstructions')
    .replace('\\(StockResearchTools.day(.now))', today)
    .replace('\\(widgets)', swiftString(source, 'widgets'))
    .replace('\\(format)', swiftString(source, 'format'));
}

class Sources {
  constructor(numbered) { this.numbered = numbered; this.list = []; }
  cite(title, url, story) {
    let index = this.list.findIndex(source => source.url === url);
    if (index < 0) { this.list.push({ title, url, story }); index = this.list.length - 1; }
    return index + 1;
  }
  note(lines) { return this.numbered && lines.length ? `\n\nCite these sources by number:\n${lines.join('\n')}` : ''; }
}

async function api(path, init = {}) {
  const response = await fetch(new URL(path, origin), { ...init, headers: { Authorization: `Bearer ${await token()}`, 'Content-Type': 'application/json', ...init.headers }, signal: AbortSignal.timeout(100000) });
  const text = await response.text();
  if (!response.ok) throw new Error(`${path.split('?')[0]} ${response.status}: ${text.slice(0, 200)}`);
  return JSON.parse(text);
}

async function dataTool(name, args, sources) {
  const query = new URLSearchParams(Object.entries(args).map(([key, value]) => [key, String(value)]));
  let payload;
  try { payload = await api(`/v1/data/tool/${name}?${query}`); }
  catch (error) { return `${name} unavailable: ${error.message}. Do not infer missing facts.`; }
  const lines = [];
  if (payload.url) lines.push(`[${sources.cite(payload.source, payload.url)}] ${payload.source}`);
  for (const row of (payload.sections ?? []).flatMap(section => section.rows).filter(row => row.url).slice(0, 20)) {
    const story = row.story ? { id: row.story, publisher: row.value, date: row.date } : undefined;
    lines.push(`[${sources.cite(row.label, row.url, story)}] ${story ? `story · ${row.value} · ${String(row.date ?? '').slice(0, 10)} · ` : ''}${row.label}`);
  }
  const text = payload.text.length > 14000 ? payload.text.slice(0, 14000) + '\nResult truncated.' : payload.text;
  return text + sources.note(lines);
}

async function stockData(args, sources) {
  const symbol = String(args.symbol || '').toUpperCase();
  if (!symbol) return 'No valid ticker. Call again with symbol set to the underlying ticker, for example QQQ.';
  if (args.kind === 'quote') return dataTool('quote', { symbols: symbol }, sources);
  if (args.kind === 'news') return dataTool('stock_news', { symbol }, sources);
  if (args.kind === 'company') return dataTool('stock_fundamentals', { symbol }, sources);
  return 'options data unavailable in this benchmark.';
}

async function answer(instructions, question, numbered) {
  const catalog = await api('/v1/data/tools.json');
  const stockTool = { type: 'function', function: { name: 'stock_data', description: 'Quote, company, news, or options for a ticker.', parameters: { type: 'object', properties: {
    kind: { type: 'string', enum: ['quote', 'company', 'news', 'options'] }, symbol: { type: 'string' }, expiration: { type: 'string' },
    side: { type: 'string', enum: ['calls', 'puts', 'both'] }, budget: { type: 'number' }, minStrike: { type: 'number' }, maxStrike: { type: 'number' } }, required: ['kind', 'symbol', 'expiration', 'side', 'budget', 'minStrike', 'maxStrike'], additionalProperties: false } } };
  const tools = [stockTool, ...catalog.tools.map(tool => ({ type: 'function', function: { name: `data_${tool.name}`, description: tool.description, parameters: tool.parameters } }))];
  const sources = new Sources(numbered);
  const messages = [{ role: 'system', content: instructions }, { role: 'user', content: `\n${question}` }];
  const calls = [];
  const started = Date.now();
  for (let round = 0; round < 12; round += 1) {
    let response;
    for (let attempt = 0; ; attempt += 1) {
      try { response = await api('/v1/ai/chat/completions', { method: 'POST', body: JSON.stringify({ messages, tools, tool_choice: 'auto', max_tokens: 1800 }) }); break; }
      catch (error) { if (attempt >= 2 || !/ (429|50[34])/.test(error.message)) throw error; await new Promise(resolve => setTimeout(resolve, 4000 * (attempt + 1))); }
    }
    const message = response.choices?.[0]?.message;
    if (!message) throw new Error('Incomplete completion');
    messages.push(message);
    if (!message.tool_calls?.length) return { text: message.content ?? '', sources: sources.list, calls, seconds: (Date.now() - started) / 1000 };
    for (const call of message.tool_calls) {
      const name = call.function?.name ?? '';
      let args = {};
      try { args = JSON.parse(call.function?.arguments || '{}'); } catch {}
      calls.push(name);
      const output = name === 'stock_data' ? await stockData(args, sources)
        : name.startsWith('data_') ? await dataTool(name.slice(5), Object.fromEntries(Object.entries(args).filter(([, value]) => ['string', 'number', 'boolean'].includes(typeof value))), sources)
        : 'Invalid tool or arguments.';
      messages.push({ role: 'tool', tool_call_id: call.id, content: output });
    }
  }
  throw new Error('Too many tool rounds');
}

function tables(text) {
  const found = [];
  let block = [];
  for (const line of [...text.split('\n'), '']) {
    if (line.trim().startsWith('|')) block.push(line.trim());
    else { if (block.length) found.push(block); block = []; }
  }
  const cells = row => row.replace(/^\|/, '').replace(/\|$/, '').split('|').map(cell => cell.trim());
  return found.map(rows => {
    const header = cells(rows[0]);
    const separator = rows[1] ? cells(rows[1]) : [];
    const body = rows.slice(2).map(cells);
    return { valid: rows.length >= 4 && separator.length === header.length && separator.every(cell => /^:?-{3,}:?$/.test(cell)) && body.every(row => row.length === header.length) && header.length <= 6, columns: header.length, rows: body.length };
  });
}

export function score(result, question) {
  const text = result.text.trim();
  const fence = /```(\w[\w-]*)\n([\s\S]*?)```/g;
  const blocks = [...text.matchAll(fence)].map(match => ({ language: match[1], body: match[2] }));
  const prose = text.replace(fence, '').split('\n').filter(line => !line.trim().startsWith('|')).join('\n');
  const lines = prose.split('\n').map(line => line.trim()).filter(Boolean);
  const lead = lines[0] ?? '';
  const words = prose.split(/\s+/).filter(Boolean).length;
  const markers = [...text.matchAll(/\[(\d{1,2})\]/g)].map(match => Number(match[1]));
  const factual = lines.filter(line => /\d/.test(line.replace(/\[\d{1,2}\]/g, '')) && !/^(\*\*)?sources?:/i.test(line));
  const cited = factual.filter(line => /\[\d{1,2}\]/.test(line));
  const found = tables(text);
  const storyBlock = blocks.find(block => block.language === 'stories');
  const storyRefs = storyBlock ? [...storyBlock.body.matchAll(/\d+/g)].map(match => Number(match[0])) : [];
  const storySources = result.sources.filter(source => source.story).length;
  const checks = {
    lead: /^\*\*[^*]{10,260}\*\*/.test(lead) && lead.split(/\s+/).length <= 40,
    leadCited: /\[\d{1,2}\]/.test(lead),
    concise: words <= 170,
    cited: factual.length === 0 || cited.length / factual.length >= 0.8,
    validCitations: markers.every(number => number >= 1 && number <= result.sources.length),
    noSourceLine: !/^\s*(\*\*)?sources?:/im.test(prose),
    noRawURLs: !/https?:\/\//.test(prose),
    noHeadings: !/^#{1,6}\s/m.test(prose),
  };
  const lastTable = text.split('\n').findLastIndex(line => line.trim().startsWith('|'));
  if (lastTable >= 0) checks.endsWithTable = text.split('\n').slice(lastTable + 1).join('\n').replace(fence, '').trim() === '';
  const citedStories = markers.filter(number => result.sources[number - 1]?.story);
  if (citedStories.length) checks.citedStoriesEmbedded = storyRefs.length >= Math.min(3, new Set(citedStories).size) && storyRefs.every(number => result.sources[number - 1]?.story);
  if (question.table) checks.table = found.length > 0 && found.every(table => table.valid);
  else checks.tableValid = found.every(table => table.valid);
  if (question.stories && storySources) checks.stories = storyRefs.length > 0 && storyRefs.every(number => result.sources[number - 1]?.story);
  const passed = Object.values(checks).filter(Boolean).length;
  return { checks, passed, total: Object.keys(checks).length, words, markers: markers.length, tables: found, storyRefs, storySources };
}

async function source(variant) {
  if (variant === 'baseline') return execFileSync('git', ['show', `${process.env.BASELINE_REF ?? 'HEAD'}:${swiftPath}`], { cwd: root, encoding: 'utf8' });
  return readFile(join(root, swiftPath), 'utf8');
}

async function pool(items, limit, work) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: limit }, async () => {
    while (next < items.length) { const index = next++; results[index] = await work(items[index]); }
  }));
  return results;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const variant = process.argv[2] ?? 'candidate';
  const only = process.argv[3]?.split(',');
  const instructions = prompt(await source(variant));
  const selected = questions.filter(question => !only || only.includes(question.id));
  const runs = await pool(selected, 3, async question => {
    try {
      const result = await answer(instructions, question.q, variant !== 'baseline');
      const graded = score(result, question);
      const failed = Object.entries(graded.checks).filter(([, ok]) => !ok).map(([name]) => name);
      console.log(`${question.id.padEnd(7)} ${graded.passed}/${graded.total} ${String(graded.words).padStart(3)}w ${result.seconds.toFixed(0).padStart(3)}s ${failed.length ? 'failed: ' + failed.join(', ') : 'all checks pass'}`);
      return { question, result, graded };
    } catch (error) {
      console.log(`${question.id.padEnd(7)} error: ${error.message}`);
      return { question, error: error.message };
    }
  });
  const done = runs.filter(run => run.graded);
  const passed = done.reduce((sum, run) => sum + run.graded.passed, 0);
  const total = done.reduce((sum, run) => sum + run.graded.total, 0);
  console.log(`${variant}: ${passed}/${total} checks (${total ? Math.round(100 * passed / total) : 0}%), ${done.length}/${runs.length} answered`);
  const out = join(root, 'screenshots', 'bench', `chat-${variant}-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
  await mkdir(dirname(out), { recursive: true });
  await writeFile(out, JSON.stringify(runs, null, 2));
  console.log(out);
}
