import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

export function emptyState() { return { version: 1, queue: [], visited: {}, stories: {}, questions: {}, domains: {}, runs: [] }; }

export async function readState(file) {
  try {
    const parsed = JSON.parse(await readFile(file, 'utf8'));
    if (parsed.version !== 1 || !Array.isArray(parsed.queue) || typeof parsed.stories !== 'object') throw new Error('Unsupported crawler state format');
    for (const task of parsed.queue) if (task.status === 'working') task.status = 'queued';
    return parsed;
  } catch (error) { if (error.code === 'ENOENT') return emptyState(); throw error; }
}

export async function writeState(file, state) {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  await writeFile(tmp, JSON.stringify(state) + '\n', { mode: 0o600 });
  await rename(tmp, file);
}
