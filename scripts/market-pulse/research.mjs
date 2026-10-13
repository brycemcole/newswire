import { token } from '../monitor/publish.mjs';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const symbols = ['SPY', 'QQQ'];

async function post(path, body) {
  const url = new URL(path, origin);
  if (url.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(url.hostname)) throw new Error('HTTPS required');
  const response = await fetch(url, { method: 'POST', headers: { Authorization: `Bearer ${await token()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${path} HTTP ${response.status}: ${payload.error?.message ?? 'request failed'}`);
  return payload;
}

export async function runResearchOnce() {
  const captured = [];
  for (const symbol of symbols) {
    try { captured.push({ symbol, result: await post('/v1/research/capture', { symbol }) }); }
    catch (error) { captured.push({ symbol, skipped: error.message }); }
  }
  const settled = await post('/v1/research/settle', {});
  return { captured, settled };
}

if (process.argv.length === 2 || process.argv.includes('--once')) console.log(JSON.stringify(await runResearchOnce(), null, 2));
else throw new Error('Usage: node --experimental-strip-types scripts/market-pulse/research.mjs [--once]');
