import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const backend = fileURLToPath(new URL('../backend/', import.meta.url));
for (const [name, account] of [['READER_TOKEN', 'reader'], ['WRITER_TOKEN', 'writer']]) {
  const service = 'com.brycecole.newswire';
  const existing = spawnSync('security', ['find-generic-password', '-s', service, '-a', account, '-w'], { encoding: 'utf8' });
  const token = existing.status === 0 ? existing.stdout.trim() : randomBytes(32).toString('hex');
  if (existing.status !== 0) {
    const saved = spawnSync('security', ['add-generic-password', '-s', service, '-a', account, '-w', token], { encoding: 'utf8' });
    if (saved.status !== 0) throw new Error(`Could not save ${account} credential in Keychain.`);
  }
  const upload = spawnSync('wrangler', ['secret', 'put', name], { cwd: backend, input: token, encoding: 'utf8' });
  if (upload.status !== 0) throw new Error(`Could not upload ${name}. ${upload.stderr.replaceAll(token, '[REDACTED]')}`);
  console.log(`${name} stored in macOS Keychain and uploaded to Cloudflare.`);
}
