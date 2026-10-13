import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';

function blockedIPv4(ip) {
  const p = ip.split('.').map(Number), a = p[0], b = p[1];
  return a === 0 || a === 10 || a === 127 || a >= 224 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && (b === 0 || b === 2 || b === 168 || (b === 88 && p[2] === 99)))
    || (a === 100 && b >= 64 && b <= 127) || (a === 198 && ([18, 19].includes(b) || (b === 51 && p[2] === 100)))
    || (a === 203 && b === 0 && p[2] === 113);
}

export function isPublicAddress(ip) {
  if (isIP(ip) === 4) return !blockedIPv4(ip);
  if (isIP(ip) !== 6) return false;
  const address = ip.toLowerCase().split('%')[0];
  if (address.startsWith('::ffff:')) return false;
  const first = Number.parseInt(address.split(':')[0] || '0', 16);
  if (first < 0x2000 || first > 0x3fff) return false;
  if (/^2001:(?:0?db8|0{0,3}10)(?::|$)/.test(address) || /^2002:/.test(address) || /^3fff:0{0,3}:0{0,3}:/i.test(address)) return false;
  return true;
}

function pinnedFetch(value, { pinnedAddresses, timeoutMs = 12000, maxBytes = 1500000, headers = {}, signal } = {}) {
  const url = new URL(value), request = url.protocol === 'https:' ? httpsRequest : httpRequest;
  const addresses = pinnedAddresses ?? [];
  if (!addresses.length) return Promise.reject(new Error('Public DNS pin is missing'));
  const lookupPinned = (_hostname, options, callback) => {
    if (options?.all) callback(null, addresses.map(item => ({ address: item.address, family: item.family ?? isIP(item.address) })));
    else callback(null, addresses[0].address, addresses[0].family ?? isIP(addresses[0].address));
  };
  return new Promise((resolve, reject) => {
    const req = request(url, { method: 'GET', headers, lookup: lookupPinned, timeout: timeoutMs, signal });
    req.on('response', response => {
      const chunks = []; let size = 0;
      response.on('data', chunk => {
        size += chunk.byteLength;
        if (size > maxBytes) { req.destroy(new Error('Response exceeds byte limit')); return; }
        chunks.push(chunk);
      });
      response.on('end', () => resolve(new Response(Buffer.concat(chunks), { status: response.statusCode, headers: response.headers })));
      response.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error(`Request timed out after ${timeoutMs}ms`)));
    req.on('error', reject);
    req.end();
  });
}

export async function validatePublicUrl(value, resolve = lookup) {
  let url;
  try { url = new URL(value); } catch { throw new Error('URL must be an absolute HTTP(S) URL without credentials'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('URL must be an absolute HTTP(S) URL without credentials');
  url.hash = '';
  if (url.port && !['80', '443'].includes(url.port)) throw new Error('Non-standard ports are blocked');
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal')) throw new Error('Local hostnames are blocked');
  const addresses = isIP(host) ? [{ address: host }] : await resolve(host, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(({ address }) => !isPublicAddress(address))) throw new Error('URL resolves to a non-public address');
  return { url, addresses };
}

async function readLimited(response, maxBytes) {
  const declared = Number(response.headers?.get?.('content-length'));
  if (Number.isFinite(declared) && declared > maxBytes) throw new Error('Response exceeds byte limit');
  if (!response.body?.getReader) {
    const data = new Uint8Array(await response.arrayBuffer());
    if (data.byteLength > maxBytes) throw new Error('Response exceeds byte limit');
    return data;
  }
  const reader = response.body.getReader(), chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) { await reader.cancel(); throw new Error('Response exceeds byte limit'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock?.(); }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}

export async function fetchPublicText(value, { fetchImpl = pinnedFetch, resolve = lookup, timeoutMs = 12000, maxBytes = 1500000, maxRedirects = 4, userAgent = 'NewswireResearchCrawler/1.0', beforeRequest = async () => true, requestWrapper = (_url, request) => request(), allowNotFound = false } = {}) {
  let current = value;
  for (let hop = 0; hop <= maxRedirects; hop += 1) {
    const { url, addresses } = await validatePublicUrl(current, resolve);
    if (!await beforeRequest(url.href)) throw new Error('Blocked by robots.txt');
    const response = await requestWrapper(url.href, () => fetchImpl(url.href, { method: 'GET', redirect: 'manual', headers: { 'User-Agent': userAgent, Accept: 'text/html,application/rss+xml,application/atom+xml,application/xml,text/xml,*/*;q=0.5' },
      signal: AbortSignal.timeout(timeoutMs), timeoutMs, maxBytes, pinnedAddresses: addresses }));
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      if (hop === maxRedirects) throw new Error('Too many redirects');
      const location = response.headers?.get?.('location');
      if (!location) throw new Error('Redirect without a location');
      current = new URL(location, url).href;
      continue;
    }
    if (response.status === 404 && allowNotFound) return { url: url.href, text: '', contentType: response.headers?.get?.('content-type') ?? '' };
    if (!response.ok) {
      const retry = Number(response.headers?.get?.('retry-after'));
      const error = new Error(`HTTP ${response.status}`);
      error.status = response.status;
      error.retryAfterMs = Number.isFinite(retry) ? Math.min(retry * 1000, 60000) : undefined;
      throw error;
    }
    const contentType = response.headers?.get?.('content-type') ?? '';
    if (contentType && !/(?:html|xml|rss|atom|text\/plain|json)/i.test(contentType)) throw new Error(`Unsupported content type: ${contentType.split(';')[0]}`);
    const bytes = await readLimited(response, maxBytes);
    return { url: url.href, text: new TextDecoder('utf-8', { fatal: false }).decode(bytes), contentType };
  }
  throw new Error('Too many redirects');
}

export function robotsAllows(robots, urlValue, userAgent = 'NewswireResearchCrawler') {
  const url = new URL(urlValue), groups = [];
  let group = { agents: [], rules: [], hasRules: false };
  for (const raw of String(robots ?? '').split(/\r?\n/)) {
    const match = /^\s*([^:#]+):\s*(.*?)\s*(?:#.*)?$/.exec(raw);
    if (!match) continue;
    const key = match[1].toLowerCase(), value = match[2].trim();
    if (key === 'user-agent') {
      if (group.hasRules) { if (group.agents.length) groups.push(group); group = { agents: [], rules: [], hasRules: false }; }
      group.agents.push(value.toLowerCase());
    } else if (key === 'allow' || key === 'disallow') {
      group.hasRules = true;
      if (value) group.rules.push({ allow: key === 'allow', path: value });
    }
  }
  if (group.agents.length) groups.push(group);
  const ua = userAgent.toLowerCase();
  const specific = groups.map(g => ({ group: g, score: Math.max(0, ...g.agents.filter(a => a !== '*' && ua.includes(a)).map(a => a.length)) })).filter(item => item.score > 0);
  const selected = specific.length ? specific.flatMap(item => item.group.rules) : groups.filter(g => g.agents.includes('*')).flatMap(g => g.rules);
  const path = `${url.pathname}${url.search}`;
  const matching = selected.filter(rule => path.startsWith(rule.path)).sort((a, b) => b.path.length - a.path.length || Number(b.allow) - Number(a.allow));
  return !matching.length || matching[0].allow;
}
