import Defuddle from 'defuddle';
import { parseHTML } from 'linkedom';

export class ExtractError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

export type Extracted = {
  url: string;
  title: string;
  author: string;
  published: string;
  site: string;
  description: string;
  image: string | null;
  word_count: number;
  paragraphs: string[];
  text: string;
};

const agents = [
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
  'Mozilla/5.0 (compatible; Defuddle/1.0; +https://defuddle.md) bot',
];
const pageLimit = 4_000_000;
const blocks = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, dd, dt';
const challenge = /enable javascript and cookies|verify you are human|are you a robot|checking your browser|access to this page has been denied|^access denied|^just a moment/i;

export function target(raw: string | null): URL {
  let url: URL;
  try { url = new URL(raw ?? ''); } catch { throw new ExtractError(400, 'url must be an absolute http(s) URL'); }
  const host = url.hostname.toLowerCase();
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || (url.port && !['80', '443'].includes(url.port))
    || !host.includes('.') || host.endsWith('.local') || host.endsWith('.internal') || host.endsWith('.workers.dev')
    || /^[\d.]+$/.test(host) || host.includes(':') || host.startsWith('[')) throw new ExtractError(400, 'url must be a public http(s) URL');
  url.hash = '';
  return url;
}

export async function download(url: URL, agent: string): Promise<{ html: string; url: string }> {
  const response = await fetch(url, {
    headers: { 'User-Agent': agent, Accept: 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.5', 'Accept-Language': 'en-US,en;q=0.9' },
    redirect: 'follow',
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new ExtractError(502, `Publisher returned ${response.status}`);
  // A public article URL can still answer with a redirect to an internal address; the final URL must pass the same public-URL rules.
  const final = target(response.url || url.href);
  const type = response.headers.get('content-type') ?? '';
  if (type && !/html|xml|text\/plain/i.test(type)) throw new ExtractError(415, `Unsupported content type ${type.split(';')[0]}`);
  const reader = response.body?.getReader();
  if (!reader) throw new ExtractError(502, 'Publisher returned an empty page');
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < pageLimit) {
    const { value, done } = await reader.read();
    if (done) break;
    chunks.push(value);
    size += value.byteLength;
  }
  if (size >= pageLimit) await reader.cancel();
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return { html: new TextDecoder().decode(bytes), url: final.href };
}

export function paragraphs(content: string): string[] {
  const { document } = parseHTML(`<!doctype html><html><body>${content}</body></html>`);
  const found: string[] = [];
  for (const element of document.querySelectorAll(blocks)) {
    if (element.querySelector(blocks) || element.closest('pre, figcaption, figure, table')) continue;
    const text = (element.textContent ?? '').replace(/\s+/g, ' ').trim();
    if (!text) continue;
    found.push(element.tagName === 'LI' ? `• ${text}` : text);
  }
  return found;
}

function httpsURL(raw: string | undefined, base: string): string | null {
  if (!raw) return null;
  try { const url = new URL(raw, base); return url.protocol === 'https:' ? url.href : null; } catch { return null; }
}

export function slim(html: string): string {
  return html
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<script\b(?![^>]*application\/ld\+json)[^>]*>[\s\S]*?<\/script>/gi, '')
    .replace(/<(style|svg|template|iframe)\b[^>]*>[\s\S]*?<\/\1>/gi, '')
    .replace(/<link\b[^>]*>/gi, '');
}

export function parse(html: string, url: string): Extracted {
  const { document } = parseHTML(slim(html));
  const result = new Defuddle(document as unknown as ConstructorParameters<typeof Defuddle>[0], { url }).parse();
  const found = paragraphs(result.content ?? '');
  return {
    url,
    title: result.title ?? '',
    author: result.author ?? '',
    published: result.published ?? '',
    site: result.site ?? '',
    description: result.description ?? '',
    image: httpsURL(result.image, url),
    word_count: found.join(' ').split(/\s+/).filter(Boolean).length,
    paragraphs: found,
    text: found.join('\n\n'),
  };
}

export async function extract(raw: string | null): Promise<Extracted> {
  const url = target(raw);
  let best: Extracted | null = null;
  let failure: unknown;
  for (const agent of agents) {
    try {
      const page = await download(url, agent);
      const result = parse(page.html, page.url);
      if (result.word_count < 150 && challenge.test(result.text)) throw new ExtractError(502, 'Publisher served a bot check');
      if (!best || result.word_count > best.word_count) best = result;
      if (best.word_count >= 150) break;
    } catch (error) { failure = error; }
  }
  if (best && best.word_count > 0) return best;
  if (failure instanceof ExtractError) throw failure;
  throw new ExtractError(502, 'No readable article content');
}
