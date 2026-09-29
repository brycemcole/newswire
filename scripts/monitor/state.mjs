import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

const file = process.env.NEWSWIRE_MONITOR_STATE ?? join(homedir(), '.config', 'newswire', 'monitor-state.json');

export async function load() {
  try {
    const parsed = JSON.parse(await readFile(file, 'utf8'));
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

export async function save(state) {
  const kept = Object.fromEntries(Object.entries(state).filter(([, entry]) => Date.now() - Date.parse(entry.at) < 21 * 86400000));
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(kept, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, file);
}

export function statePath() {
  return file;
}
