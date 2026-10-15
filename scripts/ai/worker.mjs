import { token } from '../monitor/publish.mjs';
import { complete } from './completion.mjs';

const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
if (new URL(origin).protocol !== 'https:') throw new Error('AI worker requires HTTPS');
async function api(path, body) {
  const response = await fetch(new URL(path, origin), { method: 'POST', headers: { Authorization: `Bearer ${await token()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(25000) });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    throw new Error(`AI queue HTTP ${response.status}: ${payload.error?.message ?? 'Request failed'}`);
  }
  return response.json();
}

while (true) {
  try {
    const { job } = await api('/v1/ai/worker/claim', {});
    if (!job) continue;
    const started = Date.now();
    let result, error, failure;
    try { result = await complete(job.body); } catch (cause) {
      error = true;
      failure = cause instanceof SyntaxError ? 'invalid_json'
        : cause.message === 'AI returned no answer' ? 'missing_content'
        : cause.message === 'OpenCode attempted a built-in tool' ? 'unexpected_tool'
        : cause.message === 'OpenCode did not confirm zero-cost completion' ? 'cost_unconfirmed' : 'runtime_failed';
    }
    await api('/v1/ai/worker/result', { id: job.id, result, error });
    console.log(JSON.stringify({ model: result?.model, ok: !error, ms: Date.now() - started, cost: result?.cost, provider: result?.provider, billing: result?.billing, failure }));
  } catch (error) {
    console.error(error.message);
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
}
