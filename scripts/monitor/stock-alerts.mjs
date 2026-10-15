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

export function targetReached(watch, quote, now = Date.now()) {
  if (!(quote.price > 0) || !Number.isFinite(quote.at) || now - quote.at > 300000 || quote.at > now + 60000 || !(watch.target > 0)) return false;
  return watch.direction === 'above' ? quote.price >= watch.target : quote.price <= watch.target;
}

export function activityPayload(watch, quote, now = Date.now()) {
  return { aps: { timestamp: Math.floor(now / 1000), event: 'update',
    'stale-date': Math.floor(quote.at / 1000) + 300,
    'content-state': { price: quote.price, currency: quote.currency ?? 'USD', quotedAt: quote.at / 1000 - 978307200,
      target: watch.target ?? null, direction: watch.direction, reached: targetReached(watch, quote, now) } } };
}

async function liveQuote(symbol) {
  const data = await getJson(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=1d&interval=1m&includePrePost=true`, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  const chart = data.chart?.result?.[0];
  const closes = chart?.indicators?.quote?.[0]?.close ?? [];
  let index = closes.length - 1;
  while (index >= 0 && !(closes[index] > 0)) index--;
  if (index < 0) throw new Error(`No live quote for ${symbol}`);
  const currency = chart.meta.currency ?? 'USD';
  const major = { GBp: ['GBP', 100], GBX: ['GBP', 100], ILA: ['ILS', 100], ZAc: ['ZAR', 100], ZAC: ['ZAR', 100] }[currency] ?? [currency, 1];
  return { price: closes[index] / major[1], previousClose: chart.meta.chartPreviousClose / major[1], currency: major[0], at: chart.timestamp[index] * 1000, zone: chart.meta.exchangeTimezoneName ?? 'America/New_York' };
}

export async function runStockAlerts() {
  const targets = await devices(await token());
  const symbols = [...new Set(targets.flatMap(d => [...JSON.parse(d.stock_symbols ?? '[]'), ...JSON.parse(d.price_watches ?? '[]').map(w => w.symbol)]))];
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
      for (const device of targets.filter(d => JSON.parse(d.stock_symbols ?? '[]').includes(symbol) || JSON.parse(d.price_watches ?? '[]').some(w => w.symbol === symbol))) {
        const deviceKey = `stocks:${device.token}`;
        const deviceState = state[deviceKey]?.values ?? {};
        const events = JSON.parse(device.stock_symbols ?? '[]').includes(symbol) ? movements(symbol, quote, deviceState) : [];
        const watches = JSON.parse(device.price_watches ?? '[]').filter(w => w.symbol === symbol);
        for (const watch of watches) {
          const key = `target:${watch.id}`;
          if (targetReached(watch, quote) && !deviceState[key]) {
            events.push({ key, title: `${symbol} target met: ${quote.currency} ${quote.price.toFixed(2)} (${watch.direction === 'above' ? '≥' : '≤'} ${watch.target.toFixed(2)})`, marks: [key] });
          }
          for (const activity of JSON.parse(device.live_activities ?? '[]').filter(a => a.watch_id === watch.id && a.expires_at > Date.now() / 1000)) {
            const updateKey = `activity:${activity.token}`;
            if (deviceState[updateKey]?.quoteAt >= quote.at) continue;
            // Discard stale observations instead of presenting them as live prices.
            if (Date.now() - quote.at > 300000 || quote.at > Date.now() + 60000) continue;
            const client = connect(device.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com');
            client.on('error', () => {});
            const result = await send(client, jwt, { token: activity.token }, activityPayload(watch, quote), 'liveactivity');
            client.close();
            if (result.status === 200 || result.status === 410 || result.reason === 'BadDeviceToken') {
              deviceState[updateKey] = { at: new Date().toISOString(), quoteAt: result.status === 200 ? quote.at : Number.MAX_SAFE_INTEGER };
            } else failures.push(`live activity push ${result.status} ${result.reason ?? ''}`);
          }
        }
        for (const event of events) {
          const client = connect(device.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com');
          client.on('error', () => {});
          const result = await send(client, jwt, device, { aps: { alert: { body: event.title }, sound: 'default', 'thread-id': `stock:${symbol}` }, symbol });
          client.close();
          if (result.status !== 200) { failures.push(`stock push ${result.status} ${result.reason ?? ''}`); continue; }
          for (const key of event.marks) deviceState[key] = { at: new Date().toISOString() };
          delivered++;
        }
        state[deviceKey] = { at: new Date().toISOString(), values: Object.fromEntries(Object.entries(deviceState).filter(([key, value]) => key.startsWith('target:') ? JSON.parse(device.price_watches ?? '[]').some(w => key === `target:${w.id}`) : Date.now() - Date.parse(value.at) < 2 * 86400000)) };
      }
    } catch (error) { failures.push(`${symbol}: ${error.message}`); }
  }
  const kept = Object.fromEntries(Object.entries(state).filter(([key]) => targets.some(d => key === `stocks:${d.token}`)));
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(file + '.tmp', JSON.stringify(kept), { mode: 0o600 });
  await rename(file + '.tmp', file);
  return { monitored: symbols.length, delivered, failures };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(JSON.stringify(await runStockAlerts()));
}
