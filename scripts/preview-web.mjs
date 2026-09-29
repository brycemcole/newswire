import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, extname } from 'node:path';

const root = fileURLToPath(new URL('../web/', import.meta.url));
const stories = Array.from({ length: 55 }, (_, index) => ({ id: `preview-${index}`, external_id: `preview-${index}`, title: index === 0 ? '[TEST] Newest report — terminal delivery verified' : `[TEST] Research dispatch ${String(index + 1).padStart(2, '0')}`, summary: 'Synthetic UI test fixture. This report is not real news and is never uploaded to production.', body: 'A multiline test report.\nVerify readable detail text, a safe source link, category filters, and pagination.', source: 'Preview / Fixtures', url: 'https://example.com', published_at: new Date(Date.now() - index * 60000).toISOString(), received_at: new Date().toISOString(), category: index % 2 ? 'markets' : 'technology', priority: index === 0 ? 'breaking' : 'normal', tickers: index % 2 ? ['TEST'] : [], tags: ['test-only'], agent: 'preview-agent' }));
createServer(async (request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1:8800');
  if (url.pathname === '/v1/stories') {
    response.setHeader('Content-Type', 'application/json');
    if (request.headers.authorization !== 'Bearer preview-only') { response.writeHead(401); response.end(JSON.stringify({ error: { message: 'Use preview-only for this local fixture server.' } })); return; }
    const filtered = stories.filter((s) => (!url.searchParams.get('category') || s.category === url.searchParams.get('category')) && (!url.searchParams.get('priority') || s.priority === url.searchParams.get('priority')) && (!url.searchParams.get('q') || `${s.title} ${s.source}`.toLowerCase().includes(url.searchParams.get('q').toLowerCase())));
    const start = Number(url.searchParams.get('cursor') || 0);
    const page = filtered.slice(start, start + 50);
    response.end(JSON.stringify({ stories: page, next_cursor: start + 50 < filtered.length ? String(start + 50) : null })); return;
  }
  const path = resolve(root, `.${url.pathname === '/' ? '/index.html' : url.pathname}`);
  if (!path.startsWith(root)) { response.writeHead(403); response.end(); return; }
  try { response.setHeader('Content-Type', { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json' }[extname(path)] || 'text/plain'); response.end(await readFile(path)); }
  catch { response.writeHead(404); response.end(); }
}).listen(8800, '127.0.0.1', () => console.log('Synthetic UI preview: http://127.0.0.1:8800 · token preview-only'));
