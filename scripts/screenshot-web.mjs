// Screenshots the web reader against the synthetic fixture server (scripts/preview-web.mjs).
// Usage: NODE_PATH=$(npm root -g) node scripts/screenshot-web.mjs [outDir]   (default: screenshots/web)
// Needs Playwright + Chromium (`npm i -g playwright`; in Claude Code on the web it is preinstalled and
// PLAYWRIGHT_BROWSERS_PATH is set, so do not run `playwright install`).
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const out = process.argv[2] ?? 'screenshots/web';
await mkdir(out, { recursive: true });

const server = spawn('node', [fileURLToPath(new URL('./preview-web.mjs', import.meta.url))], { stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 800));
const browser = await chromium.launch();
try {
  for (const [name, viewport] of [['desktop', { width: 1280, height: 800 }], ['phone', { width: 390, height: 844 }]]) {
    const page = await browser.newPage({ viewport });
    await page.goto('http://127.0.0.1:8800');
    // The reader is empty until a token is entered; the fixture server accepts "preview-only".
    await page.click('#connect');
    await page.fill('#token', 'preview-only');
    await page.click('#connection-form button[type=submit]');
    await page.waitForSelector('#stories > *');
    await page.waitForTimeout(1000);
    await page.screenshot({ path: `${out}/${name}.png` });
    await page.close();
  }
} finally {
  await browser.close();
  server.kill();
}
console.log(`Saved screenshots to ${out}/`);
