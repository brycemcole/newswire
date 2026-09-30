import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const appId = 'A792L5W262.com.brycecole.newswire';
const sha = (...parts) => createHash('sha256').update(Buffer.concat(parts.map(p => Buffer.from(p)))).digest();
const len = n => n < 128 ? [n] : n < 256 ? [0x81, n] : [0x82, n >> 8, n & 255];
const tlv = (tag, ...parts) => { const body = Buffer.concat(parts.map(p => Buffer.from(p))); return Buffer.concat([Buffer.from([tag, ...len(body.length)]), body]); };
const oid = dotted => { const [a, b, ...rest] = dotted.split('.').map(Number); const out = [a * 40 + b]; for (const n of rest) { const chunk = [n & 127]; for (let v = n >> 7; v; v >>= 7) chunk.unshift((v & 127) | 128); out.push(...chunk); } return tlv(6, out); };
const time = ms => tlv(0x18, new Date(ms).toISOString().replace(/[-:T]|\.\d+/g, ''));
const ecdsa384 = oid('1.2.840.10045.4.3.3');
const ecdsa256 = oid('1.2.840.10045.4.3.2');
function cert({ subject, key, signer, hash, nonce, notAfter = Date.now() + 86400000 }) {
  const extensions = nonce ? tlv(0xa3, tlv(0x30, tlv(0x30, oid('1.2.840.113635.100.8.2'), tlv(4, tlv(0x30, tlv(0xa1, tlv(4, nonce))))))) : Buffer.alloc(0);
  const alg = hash === 'sha384' ? ecdsa384 : ecdsa256;
  const tbs = tlv(0x30, tlv(0xa0, tlv(2, [2])), tlv(2, [1]), tlv(0x30, alg), tlv(0x30, tlv(0x31, tlv(0x30, oid('2.5.4.3'), tlv(0x0c, subject)))), tlv(0x30, time(Date.now() - 86400000), time(notAfter)), tlv(0x30, tlv(0x31, tlv(0x30, oid('2.5.4.3'), tlv(0x0c, subject)))), key.publicKey.export({ type: 'spki', format: 'der' }), extensions);
  return { der: tlv(0x30, tbs, tlv(0x30, alg), tlv(3, [0], sign(hash, tbs, signer.privateKey))), ...key };
}
const cbor = value => {
  const head = (major, n) => n < 24 ? Buffer.from([major << 5 | n]) : n < 256 ? Buffer.from([major << 5 | 24, n]) : Buffer.from([major << 5 | 25, n >> 8, n & 255]);
  if (typeof value === 'string') return Buffer.concat([head(3, Buffer.byteLength(value)), Buffer.from(value)]);
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  return Buffer.concat([head(5, Object.keys(value).length), ...Object.entries(value).flatMap(([k, v]) => [cbor(k), cbor(v)])]);
};
const pair = curve => generateKeyPairSync('ec', { namedCurve: curve });
const pemOf = der => `-----BEGIN CERTIFICATE-----\n${der.toString('base64')}\n-----END CERTIFICATE-----`;

const rootKey = pair('secp384r1');
const root = cert({ subject: 'Test Root', key: rootKey, signer: rootKey, hash: 'sha384' });
const caKey = pair('secp384r1');
const ca = cert({ subject: 'Test CA', key: caKey, signer: rootKey, hash: 'sha384' });

function device(counter = 0) {
  const key = pair('prime256v1');
  const point = Buffer.from(key.publicKey.export({ type: 'spki', format: 'der' })).subarray(-65);
  return { key, point, keyId: sha(point), counter };
}
function authData(keyId, counter, { app = appId, aaguid = 'appattestdevelop', attested = true } = {}) {
  const head = Buffer.concat([sha(app), Buffer.from([attested ? 0x40 : 0]), Buffer.from([counter >>> 24, counter >>> 16 & 255, counter >>> 8 & 255, counter & 255])]);
  return attested ? Buffer.concat([head, Buffer.from(aaguid, 'latin1'), Buffer.from([0, keyId.length]), keyId]) : head;
}
function attestation(dev, challenge, opts = {}) {
  const data = opts.authData ?? authData(dev.keyId, 0, opts);
  const nonce = sha(data, sha(challenge));
  const leaf = cert({ subject: 'Test Leaf', key: dev.key, signer: opts.signer ?? caKey, hash: 'sha256', nonce: opts.nonce ?? nonce, notAfter: opts.notAfter });
  const chain = opts.chain ?? [leaf.der, ca.der];
  return cbor({ fmt: 'apple-appattest', attStmt: { x5c: chain, receipt: Buffer.from('r') }, authData: data }).toString('base64');
}
function assertion(dev, challenge, counter, opts = {}) {
  const data = authData(dev.keyId, counter, { ...opts, attested: false });
  const signature = sign('sha256', sha(data, sha(challenge)), opts.key ?? dev.key.privateKey);
  return cbor({ signature, authenticatorData: data }).toString('base64');
}

let mf;
const call = (path, init) => mf.dispatchFetch(`https://newswire.test${path}`, init);
const challenge = async () => (await (await call('/v1/attest/challenge')).json()).challenge;
const postJSON = (path, body) => call(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const enroll = async (dev, opts) => { const c = opts?.challenge ?? await challenge(); return postJSON('/v1/attest', { key_id: dev.keyId.toString('base64'), challenge: c, attestation: attestation(dev, c, opts) }); };
const renew = async (dev, counter, opts) => { const c = opts?.challenge ?? await challenge(); return postJSON('/v1/attest/session', { key_id: dev.keyId.toString('base64'), challenge: c, assertion: assertion(dev, c, counter, opts) }); };
const stories = token => call('/v1/stories', { headers: { Authorization: `Bearer ${token}` } });

before(async () => {
  const script = (await build({ entryPoints: ['src/index.ts'], bundle: true, format: 'esm', write: false })).outputFiles[0].text;
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'test', modules: true, script, compatibilityDate: '2026-09-06', d1Databases: ['DB'], bindings: { WRITER_TOKEN: 'writer', ATTEST_ROOT_CA: pemOf(root.der), ATTEST_APP_ID: appId }, serviceBindings: { ASSETS: () => new Response('shell') } }] }));
  const db = await mf.getD1Database('DB');
  for (const file of (await readdir(new URL('../migrations/', import.meta.url))).sort()) {
    await db.batch((await readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8')).split(';').filter(s => s.trim()).map(s => db.prepare(s)));
  }
});
after(async () => { await mf?.dispose(); });

test('attested device enrolls, reads, renews with a fresh assertion and cannot write', async () => {
  const dev = device();
  const enrolled = await enroll(dev);
  assert.equal(enrolled.status, 201);
  const { token, expires_at } = await enrolled.json();
  assert.match(token, /^[0-9a-f]{64}$/);
  assert.ok(Date.parse(expires_at) > Date.now() + 6 * 86400000);
  assert.equal((await stories(token)).status, 200);
  assert.equal((await call('/v1/ingest?title=x', { headers: { Authorization: `Bearer ${token}` } })).status, 403);
  assert.equal((await stories('0'.repeat(64))).status, 401);

  const renewed = await renew(dev, 1);
  assert.equal(renewed.status, 201);
  assert.equal((await stories((await renewed.json()).token)).status, 200);
  assert.equal((await renew(dev, 1)).status, 401, 'counter replay');
  assert.equal((await renew(dev, 5, { key: device().key.privateKey })).status, 401, 'wrong signing key');
  assert.equal((await renew(dev, 6, { app: 'X.other.app' })).status, 401, 'wrong app');
  assert.equal((await renew(device(), 1)).status, 404, 'unknown key');
  assert.equal((await renew(dev, 7)).status, 201);
});

test('attestation is rejected when anything is off', async () => {
  const dev = device();
  const otherCA = cert({ subject: 'Evil CA', key: pair('secp384r1'), signer: rootKey, hash: 'sha384' });
  const cases = {
    'wrong nonce': { nonce: Buffer.alloc(32, 1) },
    'wrong app id': { app: 'X.other.app' },
    'nonzero counter': { authData: authData(dev.keyId, 3) },
    'unknown aaguid': { aaguid: 'notappattestxxxx' },
    'leaf not signed by intermediate': { signer: pair('secp384r1') },
    'expired leaf': { notAfter: Date.now() - 3600000 },
    'wrong key id': { authData: authData(sha('other'), 0) },
  };
  for (const [name, opts] of Object.entries(cases)) assert.equal((await enroll(dev, opts)).status, 401, name);
  assert.equal((await enroll(dev, { chain: [otherCA.der, ca.der] })).status, 401, 'foreign leaf');
  assert.equal((await postJSON('/v1/attest', { key_id: dev.keyId.toString('base64'), challenge: await challenge(), attestation: 'AAAA' })).status, 401);
  assert.equal((await postJSON('/v1/attest', { key_id: dev.keyId.toString('base64'), challenge: 'x', attestation: 'AAAA' })).status, 401);
  assert.equal((await postJSON('/v1/attest', { key_id: '***', challenge: await challenge(), attestation: 'AAAA' })).status, 400);
  const db = await mf.getD1Database('DB');
  assert.equal((await db.prepare('SELECT count(*) AS n FROM attested_devices WHERE key_id = ?').bind(dev.keyId.toString('base64')).first()).n, 0);
});

test('challenges expire and are bound to the server secret', async () => {
  const dev = device();
  const good = await challenge();
  const [issued, nonce, mac] = good.split('.');
  assert.equal((await enroll(dev, { challenge: `${Date.now() - 400000}.${nonce}.${mac}` })).status, 401);
  assert.equal((await enroll(dev, { challenge: `${issued}.${nonce}.${mac.slice(1)}A` })).status, 401);
  assert.equal((await enroll(dev, { challenge: good })).status, 201);
  assert.equal((await call('/v1/attest/other')).status, 404);
  assert.equal((await call('/v1/attest/challenge', { method: 'POST' })).status, 405);
});
