import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const source = (await build({ entryPoints: ['src/extract.ts'], bundle: true, format: 'esm', platform: 'neutral', mainFields: ['module', 'main'], write: false })).outputFiles[0].text;
const { download, parse, target } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

const htmlResponse = (url, html = '<p>ok</p>') => {
  const bytes = new TextEncoder().encode(html);
  return {
    ok: true, status: 200, url,
    headers: { get: () => 'text/html' },
    body: { getReader: () => { let done = false; return { read: async () => done ? { done: true, value: undefined } : (done = true, { done: false, value: bytes }), cancel: async () => undefined }; } },
  };
};

test('extraction keeps the article and drops page chrome', () => {
  const body = Array.from({ length: 6 }, (_, i) => `<p>Paragraph ${i + 1} explains how the central bank weighed inflation, hiring and trade data before its decision this week.</p>`).join('');
  const html = `<!doctype html><html><head><title>Rates hold steady</title><meta property="og:image" content="/lead.jpg"></head><body>
    <nav><a href="/">Home</a><a href="/markets">Markets</a></nav>
    <article><h1>Rates hold steady</h1>${body}<ul><li>Inflation cooled for a third straight month across most categories.</li><li>Hiring slowed in manufacturing while services stayed firm.</li></ul>${body}</article>
    <aside class="related"><h3>Related stories</h3><a href="/x">Other headline</a></aside>
    <footer>Copyright Example News</footer></body></html>`;
  const result = parse(html, 'https://news.example.com/rates');
  assert.equal(result.title, 'Rates hold steady');
  assert.equal(result.image, 'https://news.example.com/lead.jpg');
  assert.ok(result.paragraphs.includes('• Inflation cooled for a third straight month across most categories.'));
  assert.ok(result.paragraphs.filter(p => p.startsWith('Paragraph')).length === 12);
  assert.ok(!result.text.includes('Copyright') && !result.text.includes('Related stories') && !result.text.includes('Markets'));
  assert.equal(result.text, result.paragraphs.join('\n\n'));
});

test('only public web URLs are fetched', () => {
  for (const url of [null, 'notaurl', 'ftp://example.com/a', 'https://localhost/a', 'https://10.0.0.1/a', 'https://[::1]/a', 'https://user:pw@example.com/a', 'https://example.com:8443/a', 'https://printer.local/a', 'https://bryce-newswire.bryce-e19.workers.dev/v1/stories'])
    assert.throws(() => target(url), { status: 400 }, String(url));
  assert.equal(target('https://www.example.com/story#top').href, 'https://www.example.com/story');
});

test('a redirect to a non-public address is rejected', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => htmlResponse('http://169.254.169.254/latest/meta-data');
  try {
    await assert.rejects(() => download(new URL('https://www.example.com/story'), 'agent'), { status: 400 });
  } finally {
    globalThis.fetch = original;
  }
});

test('a redirect to another public URL is followed and reported', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => htmlResponse('https://cdn.www.example.com/story?ref=amp');
  try {
    const page = await download(new URL('https://www.example.com/story'), 'agent');
    assert.equal(page.url, 'https://cdn.www.example.com/story?ref=amp');
    assert.match(page.html, /<p>ok<\/p>/);
  } finally {
    globalThis.fetch = original;
  }
});
