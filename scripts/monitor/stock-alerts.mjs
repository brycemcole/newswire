import { connect } from 'node:http2';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { credentials, devices, send } from './apns.mjs';
import { token } from './publish.mjs';
import { getJson, day } from './fetch.mjs';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';

export function movements(symbol, quote, state, now = Date.now()) {
  if (!(quote.price > 0 && quote.previousClose > 0) || !Number.isFinite(quote.at) || now - quote.at > 300000 || quote.at > now + 60000) return [];
  const session = day(quote.at, quote.zone);
  const change = (quote.price / quote.previousClose - 1) * 100;
  const direction = change >= 0 ? 'up' : 'down';
  const events = [];
  const threshold = [10, 5].find(level => Math.abs(change) + 1e-8 >= level);
  if (threshold) {
    const key = `${symbol}:${session}:${direction}:${threshold}`;
    if (!state[key]) events.push({ key, title: `${symbol} ${direction} ${Math.abs(change).toFixed(2)}% today · $${quote.price.toFixed(2)}`, marks: [key, `${symbol}:${session}:${direction}:5`] });
  }
  const sampleKey = `sample:${symbol}`;
  const samples = (state[sampleKey]?.samples ?? []).filter(s => quote.at - s.at <= 300000 && s.at < quote.at && day(s.at, quote.zone) === session);
  const baseline = samples.find(s => quote.at - s.at >= 60000);
  if (baseline) {
    const rapid = (quote.price / baseline.price - 1) * 100;
    const rapidDirection = rapid >= 0 ? 'up' : 'down';
    const key = `${symbol}:rapid:${rapidDirection}`;
    if (Math.abs(rapid) >= 2 && now - Date.parse(state[key]?.at ?? '1970-01-01') >= 1800000 && !events.length) {
      events.push({ key, title: `${symbol} moving fast: ${rapidDirection} ${Math.abs(rapid).toFixed(2)}% in ${Math.round((quote.at - baseline.at) / 60000)} min · $${quote.price.toFixed(2)}`, marks: [key] });
    }
  }
  samples.push({ at: quote.at, price: quote.price });
  state[sampleKey] = { at: new Date(now).toISOString(), samples };
  return events;
}

async function liveQuote(symbol) {
  const data = await getJson(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=1d&interval=1m&includePrePost=true`, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  const chart = data.chart?.result?.[0];
  const closes = chart?.indicators?.quote?.[0]?.close ?? [];
  let index = closes.length - 1;
  while (index >= 0 && !(closes[index] > 0)) index--;
  if (index < 0) throw new Error(`No live quote for ${symbol}`);
  return { price: closes[index], previousClose: chart.meta.chartPreviousClose, at: chart.timestamp[index] * 1000, zone: chart.meta.exchangeTimezoneName ?? 'America/New_York' };
}

export async function runStockAlerts() {
  const targets = await devices(await token());
  const symbols = [...new Set(targets.flatMap(d => JSON.parse(d.stock_symbols ?? '[]')))];
  if (!symbols.length) return { monitored: 0, delivered: 0, failures: [] };
  const directory = join(homedir(), '.config', 'newswire');
  const file = join(directory, 'stock-alert-state.json');
  const state = JSON.parse(await readFile(file, 'utf8').catch(() => '{}'));
  const jwt = await credentials();
  let delivered = 0;
  const failures = [];
  for (const symbol of symbols) {
    try {
      const quote = await liveQuote(symbol);
      for (const device of targets.filter(d => JSON.parse(d.stock_symbols ?? '[]').includes(symbol))) {
        const deviceKey = `stocks:${device.token}`;
        const deviceState = state[deviceKey]?.values ?? {};
        const events = movements(symbol, quote, deviceState);
        for (const event of events) {
          const client = connect(device.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com');
          client.on('error', () => {});
          const result = await send(client, jwt, device, { aps: { alert: { body: event.title }, sound: 'default', 'thread-id': `stock:${symbol}` }, symbol });
          client.close();
          if (result.status !== 200) { failures.push(`stock push ${result.status} ${result.reason ?? ''}`); continue; }
          for (const key of event.marks) deviceState[key] = { at: new Date().toISOString() };
          delivered++;
        }
        state[deviceKey] = { at: new Date().toISOString(), values: Object.fromEntries(Object.entries(deviceState).filter(([, value]) => Date.now() - Date.parse(value.at) < 2 * 86400000)) };
      }
    } catch (error) { failures.push(`${symbol}: ${error.message}`); }
  }
  const kept = Object.fromEntries(Object.entries(state).filter(([, value]) => Date.now() - Date.parse(value.at) < 2 * 86400000));
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(file + '.tmp', JSON.stringify(kept), { mode: 0o600 });
  await rename(file + '.tmp', file);
  return { monitored: symbols.length, delivered, failures };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(JSON.stringify(await runStockAlerts()));
}
