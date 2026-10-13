import { validatePublicUrl } from './network.mjs';
import { canonicalUrl } from './sources.mjs';

export async function collectScrolledLinks(startUrl, { browserFactory, maxScrolls = 3, idleMs = 500, timeoutMs = 12000, resolve, allowedDomains = [] } = {}) {
  const links = new Map();
  const startHost = new URL(startUrl).hostname.toLowerCase();
  if (!allowedDomains.some(domain => startHost === domain || startHost.endsWith(`.${domain}`))) throw new Error('Browser scrolling is not enabled for this source host');
  let browser;
  try {
    browser = await browserFactory();
    const context = await browser.newContext({ serviceWorkers: 'block', acceptDownloads: false });
    const page = await context.newPage();
    await page.route('**/*', async route => {
      const request = route.request(), url = request.url();
      try {
        if (!['http:', 'https:'].includes(new URL(url).protocol)) throw new Error('Blocked browser scheme');
        if (new URL(url).hostname.toLowerCase() !== startHost) throw new Error('Cross-host browser requests are blocked');
        await validatePublicUrl(url, resolve);
        if (['image', 'media', 'font'].includes(request.resourceType())) return route.abort();
        return route.continue();
      } catch { return route.abort(); }
    });
    await page.goto(startUrl, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
    for (let step = 0; step <= maxScrolls; step += 1) {
      const found = await page.locator('a[href]').evaluateAll(anchors => anchors.map(a => ({ url: a.href, title: (a.innerText || a.getAttribute('aria-label') || '').trim() })));
      let added = 0;
      for (const link of found) {
        const url = canonicalUrl(link.url);
        if (!url || !link.title || links.has(url)) continue;
        links.set(url, { url, title: link.title.slice(0, 500) });
        added += 1;
      }
      if (step === maxScrolls || added === 0) break;
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
      await page.waitForTimeout(idleMs);
    }
    await context.close();
  } finally { await browser?.close(); }
  return [...links.values()];
}

export async function playwrightFactory() {
  const { chromium } = await import('playwright');
  return chromium.launch({ headless: true, ...(process.env.NEWSWIRE_CHROMIUM_PATH ? { executablePath: process.env.NEWSWIRE_CHROMIUM_PATH } : {}) });
}
