import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const backend = fileURLToPath(new URL('../../backend/', import.meta.url));
const { build } = createRequire(backend)('esbuild');

export async function loadModule(entry) {
  const bundle = await build({ absWorkingDir: backend, entryPoints: [entry], bundle: true, format: 'esm', platform: 'node', write: false });
  return import(`data:text/javascript,${encodeURIComponent(bundle.outputFiles[0].text)}`);
}
