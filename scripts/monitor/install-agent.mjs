import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const label = 'com.brycecole.newswire.monitor';
const home = homedir();
const runner = resolve(dirname(fileURLToPath(import.meta.url)), 'run.mjs');
const logs = join(home, 'Library', 'Logs', 'newswire');
const plistPath = join(home, 'Library', 'LaunchAgents', label + '.plist');
const interval = Number(process.argv.find(argument => argument.startsWith('--interval='))?.slice(11) ?? 60);

const plist = [
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
  '<plist version="1.0">',
  '<dict>',
  '  <key>Label</key><string>' + label + '</string>',
  '  <key>ProgramArguments</key>',
  '  <array>',
  '    <string>' + process.execPath + '</string>',
  '    <string>' + runner + '</string>',
  '  </array>',
  '  <key>StartInterval</key><integer>' + interval + '</integer>',
  '  <key>RunAtLoad</key><false/>',
  '  <key>ProcessType</key><string>Background</string>',
  '  <key>StandardOutPath</key><string>' + join(logs, 'monitor.log') + '</string>',
  '  <key>StandardErrorPath</key><string>' + join(logs, 'monitor.error.log') + '</string>',
  '  <key>WorkingDirectory</key><string>' + resolve(dirname(runner), '..', '..') + '</string>',
  '</dict>',
  '</plist>',
  '',
].join('\n');

await mkdir(logs, { recursive: true });
await mkdir(dirname(plistPath), { recursive: true });
await writeFile(plistPath, plist, { mode: 0o644 });

const target = `gui/${process.getuid()}/${label}`;
spawnSync('launchctl', ['bootout', target], { stdio: 'ignore' });
const boot = spawnSync('launchctl', ['bootstrap', `gui/${process.getuid()}`, plistPath], { encoding: 'utf8' });
if (boot.status !== 0) {
  console.error(boot.stderr?.trim() || 'launchctl bootstrap failed');
  process.exitCode = 1;
} else {
  console.log(`Loaded ${label} every ${interval}s. Logs: ${join(logs, 'monitor.log')}`);
}
