import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

const filename = process.argv[2];
if (!filename) throw new Error('Usage: node scripts/upload-story.mjs story.json [--get]');
const base = process.env.NEWSWIRE_URL;
if (!base) throw new Error('Set NEWSWIRE_URL to the deployed HTTPS origin.');
const stored = process.env.NEWSWIRE_WRITER_TOKEN ? null : spawnSync('security', ['find-generic-password', '-s', 'com.brycecole.newswire', '-a', 'writer', '-w'], { encoding: 'utf8' });
const token = process.env.NEWSWIRE_WRITER_TOKEN || (stored?.status === 0 ? stored.stdout.trim() : '');
if (!token) throw new Error('Set NEWSWIRE_WRITER_TOKEN or provision a writer token in Keychain.');
const story = JSON.parse(await readFile(filename, 'utf8'));
const useGet = process.argv.includes('--get');
const url = new URL(useGet ? '/v1/ingest' : '/v1/stories', base);
if (url.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(url.hostname)) throw new Error('HTTPS required.');
if (useGet) for (const [key, value] of Object.entries(story)) url.searchParams.set(key, Array.isArray(value) ? value.join(',') : value);
const response = await fetch(url, { method: useGet ? 'GET' : 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, ...(useGet ? {} : { body: JSON.stringify(story) }) });
console.log(JSON.stringify(await response.json(), null, 2));
if (!response.ok) process.exitCode = 1;
