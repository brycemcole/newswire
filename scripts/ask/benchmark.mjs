import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { complete as deepSeekComplete, model as deepSeekModel } from '../ai/deepseek.mjs';
import { goComplete, goModel } from '../ai/completion.mjs';

const args = process.argv.slice(2);
function option(name, fallback) { const i = args.indexOf(name); return i < 0 ? fallback : args[i + 1]; }
const provider = option('--provider', 'newswire');
if (!['openai', 'newswire', 'deepseek', 'go'].includes(provider)) throw new Error('Provider must be openai, newswire, deepseek or go');
const model = provider === 'openai' ? option('--model', 'gpt-5.4-mini-2026-03-17') : provider === 'newswire' ? 'server-configured' : provider === 'go' ? goModel : deepSeekModel;
const complete = provider === 'openai' ? openAIComplete : provider === 'newswire' ? serverComplete : provider === 'go' ? body => goComplete(body, { signal: AbortSignal.timeout(120000) }) : deepSeekComplete;
const before = option('--before');
if (!before) throw new Error('Usage: node scripts/ask/benchmark.mjs --before <saved StockResearch.swift> [--out <directory>] [--case low-attention|global|quote]');
const out = resolve(option('--out', 'screenshots/ask-benchmark/results'));
const base = process.env.NEWSWIRE_URL || 'https://bryce-newswire.bryce-e19.workers.dev';
const token = process.env.NEWSWIRE_READER_TOKEN || (() => {
  const result = spawnSync('security', ['find-generic-password', '-s', 'com.brycecole.newswire', '-a', option('--credential', 'reader'), '-w'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error('Reader credential unavailable');
  return result.stdout.trim();
})();
const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Tokyo' }).format(new Date());
async function openAIComplete(body) {
  if (!process.env.OPENAI_API_KEY) throw new Error('OPENAI_API_KEY unavailable');
  const input = body.messages.slice(1).flatMap(message => {
    if (message.role === 'tool') return [{ type: 'function_call_output', call_id: message.tool_call_id, output: message.content }];
    return [
      ...(message.content ? [{ role: message.role, content: message.content }] : []),
      ...(message.tool_calls || []).map(call => ({ type: 'function_call', call_id: call.id, name: call.function.name, arguments: call.function.arguments })),
    ];
  });
  const web = args.includes('--web');
  const guidance = web ? '\n\nWeb search: prefer Newswire tools for prices, filings and economic data. Use web_search for recent news, events or facts Newswire tools do not cover. Cite web claims with inline Markdown links [publisher](url).' : '';
  const response = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST', headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, store: false, instructions: body.messages[0].content + guidance, input,
      reasoning: { effort: 'low' }, max_output_tokens: 6000,
      ...(body.tools ? { tools: [...body.tools.map(({ function: tool }) => ({ type: 'function', ...tool, strict: false })), ...(web ? [{ type: 'web_search' }] : [])], tool_choice: 'auto', parallel_tool_calls: true } : {}),
    }), signal: AbortSignal.timeout(180000),
  });
  if (!response.ok) throw new Error(`OpenAI HTTP ${response.status}`);
  const result = await response.json();
  if (result.status !== 'completed') throw new Error(`OpenAI response ${result.status}`);
  const output = result.output || [];
  const content = output.filter(item => item.type === 'message').flatMap(item => item.content || []).filter(part => part.type === 'output_text').map(part => part.text).join('');
  const calls = output.filter(item => item.type === 'function_call').map(call => ({ id: call.call_id, type: 'function', function: { name: call.name, arguments: call.arguments } }));
  return { model: result.model, choices: [{ message: { role: 'assistant', content, ...(calls.length ? { tool_calls: calls } : {}) } }],
    webSearches: output.filter(item => item.type === 'web_search_call'),
    usage: { prompt_tokens: result.usage?.input_tokens, completion_tokens: result.usage?.output_tokens } };
}
async function serverComplete(body) {
  const response = await fetch(new URL('/v1/ai/chat/completions', base), {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(120000),
  });
  if (!response.ok) throw new Error(`Newswire AI HTTP ${response.status}`);
  const result = await response.json();
  if (result.choices?.[0]?.finish_reason === 'length') throw new Error('Newswire AI returned an incomplete answer');
  return result;
}
function block(source, name) {
  const match = source.match(new RegExp(`(?:let|var) ${name} = """\\n([\\s\\S]*?)\\n\\s*"""`));
  if (!match) throw new Error(`Missing Swift prompt block: ${name}`);
  return match[1].split('\n').map(line => line.trimStart()).join('\n');
}
function instructions(source) {
  const format = block(source, 'format');
  const widgets = block(source, 'widgets');
  let prompt = block(source, 'marketInstructions').replaceAll('\\(StockResearchTools.day(.now))', date)
    .replaceAll('\\(widgets)', widgets).replaceAll('\\(format)', format);
  if (source.includes('Self.discoveryInstructions')) prompt += '\n\n' + block(source, 'discoveryInstructions');
  const screen = source.match(/private static let screenInstructions = ("[^\n]+")/);
  const portfolio = source.match(/Self\.screenInstructions \+ ("[^\n]+")/);
  if (screen) prompt += '\n\n' + JSON.parse(screen[1]);
  if (portfolio) prompt += JSON.parse(portfolio[1]);
  if (prompt.includes('\\(')) throw new Error('Unresolved Swift prompt interpolation');
  return prompt;
}
const variants = [
  { name: 'before', prompt: instructions(await readFile(before, 'utf8')) },
  { name: 'after', prompt: instructions(await readFile('ios/Sources/StockResearch.swift', 'utf8')) },
];
async function get(path, query = {}) {
  const url = new URL(path, base);
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, String(value));
  const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(45000) });
  if (!response.ok) throw new Error(`Data HTTP ${response.status}`);
  return response.json();
}
const catalog = (await get('/v1/data/tools.json')).tools;
const tools = catalog.map(tool => ({ type: 'function', function: { name: `data_${tool.name}`, description: tool.description, parameters: tool.parameters } }));
const allowed = new Set(tools.map(tool => tool.function.name));
const cache = new Map();
const cases = [
  { id: 'low-attention', question: 'find 10 stocks that are outperforming but have low attention?' },
  { id: 'global', question: 'Find 5 outperforming stocks across US, European and Japanese markets and different sectors. Compare their three-month performance and investigate what is driving it.' },
  { id: 'quote', question: 'What is the latest AAPL share price?' },
].filter(item => !option('--case') || item.id === option('--case'));
if (!cases.length) throw new Error('Unknown benchmark case');
await mkdir(out, { recursive: true });
await writeFile(`${out}/prompts.json`, JSON.stringify({ date, model, variants, tools }, null, 2));
function sourceText(payload, sources) {
  function cite(url, title) {
    if (!sources.has(url)) sources.set(url, { number: sources.size + 1, title });
    return `[${sources.get(url).number}] ${title}`;
  }
  const citations = [];
  if (payload.url) citations.push(cite(payload.url, payload.source));
  for (const row of (payload.sections || []).flatMap(section => section.rows || []).filter(row => row.url).slice(0, 20)) citations.push(cite(row.url, row.label));
  const text = payload.text || JSON.stringify(payload);
  return text.slice(0, 14000) + (text.length > 14000 ? '\nResult truncated. Narrow the query.' : '') + '\n\nCite these sources by number:\n' + citations.join('\n');
}
async function callTool(name, parameters) {
  if (!allowed.has(name)) return { error: 'Invalid tool. Use an available data_ tool.' };
  const entries = Object.entries(parameters).sort(([a], [b]) => a.localeCompare(b));
  const key = JSON.stringify([name, entries]);
  if (!cache.has(key)) cache.set(key, get(`/v1/data/tool/${name.slice(5)}`, Object.fromEntries(entries))
    .catch(error => ({ error: `${name} unavailable: ${error.message}. Try a relevant alternative. Do not infer missing facts.` })));
  return cache.get(key);
}
function metrics(trace, answer) {
  const calls = trace.flatMap(round => round.calls || []);
  const screens = calls.filter(call => /data_(screener|stock_screens)$/.test(call.name));
  const stocks = new Set(calls.filter(call => /data_stock_(history|fundamentals|news)$/.test(call.name)).map(call => call.arguments.symbol));
  return {
    rounds: trace.length, toolCalls: calls.length,
    webSearches: trace.reduce((count, step) => count + (step.webSearches?.length || 0), 0),
    failedCalls: calls.filter(call => call.error).length,
    screenerQueries: screens.length,
    explicitSectors: [...new Set(screens.map(call => call.arguments.sector).filter(Boolean))],
    regions: [...new Set(screens.flatMap(call => String(call.arguments.region || 'us').split(/[,\s]+/)))],
    individuallyResearchedSymbols: [...stocks].filter(Boolean),
    historySymbols: [...new Set(calls.filter(call => call.name === 'data_stock_history').map(call => call.arguments.symbol))],
    fundamentalsSymbols: [...new Set(calls.filter(call => call.name === 'data_stock_fundamentals').map(call => call.arguments.symbol))],
    newsSymbols: [...new Set(calls.filter(call => call.name === 'data_stock_news').map(call => call.arguments.symbol))],
    answerWords: answer.split(/\s+/).filter(Boolean).length,
  };
}
async function run(test, variant) {
  const started = Date.now();
  const messages = [{ role: 'system', content: variant.prompt }, { role: 'user', content: `\n${test.question}` }];
  const trace = [], sources = new Map();
  let answer = '', error, providerModel, totalCalls = 0;
  const usage = { prompt_tokens: 0, completion_tokens: 0 };
  try {
    for (let round = 0; round <= 16; round++) {
      const final = round === 16 || totalCalls >= 60;
      const request = { messages: final ? [{ role: 'system', content: variant.prompt + '\n\nAnswer now using only the research already gathered. Acknowledge any missing information.' }, ...messages.slice(1)] : messages,
        max_tokens: 1800, temperature: 0, ...(final ? {} : { tools, tool_choice: 'auto' }) };
      const response = await complete(request, { timeout: 120000 });
      providerModel = response.model;
      for (const key of Object.keys(usage)) usage[key] += response.usage?.[key] || 0;
      const message = response.choices[0].message;
      messages.push(message);
      const calls = message.tool_calls || [];
      const step = { round, content: message.content, calls: [], webSearches: response.webSearches };
      trace.push(step);
      if (!calls.length) { answer = message.content || ''; break; }
      for (const call of calls) {
        const parameters = JSON.parse(call.function.arguments || '{}');
        const payload = totalCalls >= 60 ? { error: 'Benchmark tool budget reached; answer with gathered evidence.' } : await callTool(call.function.name, parameters);
        totalCalls++;
        const content = payload.error || sourceText(payload, sources);
        step.calls.push({ name: call.function.name, arguments: parameters, error: payload.error, output: content });
        messages.push({ role: 'tool', tool_call_id: call.id, content });
      }
      console.log(`${test.id}/${variant.name}: round ${round + 1}, ${totalCalls} tools`);
    }
    if (!answer) throw new Error('No final answer');
  } catch (failure) { error = failure.message; }
  const result = { case: test.id, question: test.question, variant: variant.name, date, model: providerModel || model, error,
    elapsedSeconds: (Date.now() - started) / 1000, usage, metrics: metrics(trace, answer), answer, sources: [...sources], trace };
  await writeFile(`${out}/${test.id}-${variant.name}.json`, JSON.stringify(result, null, 2));
  await writeFile(`${out}/${test.id}-${variant.name}.md`, `# ${test.id} — ${variant.name}\n\n${answer || error}\n`);
  console.log(JSON.stringify({ case: test.id, variant: variant.name, error, seconds: result.elapsedSeconds, ...result.metrics }));
  return result;
}
const results = [];
for (const test of cases) results.push(...await Promise.all(variants.map(variant => run(test, variant))));
await writeFile(`${out}/summary.json`, JSON.stringify(results.map(({ trace, sources, ...result }) => result), null, 2));
await writeFile(`${out}/tool-snapshot.json`, JSON.stringify(await Promise.all([...cache].map(async ([key, value]) => [key, await value])), null, 2));
if (results.some(result => result.error)) process.exitCode = 1;
