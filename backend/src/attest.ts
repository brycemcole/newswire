const encoder = new TextEncoder();
const appleRoot = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;
const nonceOID = '1.2.840.113635.100.8.2';
const curves: Record<string, { name: string; size: number }> = { '1.2.840.10045.3.1.7': { name: 'P-256', size: 32 }, '1.3.132.0.34': { name: 'P-384', size: 48 } };
const hashes: Record<string, string> = { '1.2.840.10045.4.3.2': 'SHA-256', '1.2.840.10045.4.3.3': 'SHA-384' };
const aaguids = ['appattest\0\0\0\0\0\0\0', 'appattestdevelop'];

export class AttestError extends Error {}
function fail(message: string): never { throw new AttestError(message); }

interface Der { tag: number; content: Uint8Array; raw: Uint8Array }
function der(buf: Uint8Array, offset = 0): Der {
  if (offset + 2 > buf.length) fail('Malformed certificate');
  const tag = buf[offset];
  let length = buf[offset + 1];
  let header = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (!count || count > 3 || offset + 2 + count > buf.length) fail('Malformed certificate');
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + buf[offset + 2 + i];
    header += count;
  }
  if (offset + header + length > buf.length) fail('Malformed certificate');
  return { tag, content: buf.subarray(offset + header, offset + header + length), raw: buf.subarray(offset, offset + header + length) };
}
function children(node: Der): Der[] {
  const result: Der[] = [];
  for (let offset = 0; offset < node.content.length;) {
    const child = der(node.content, offset);
    result.push(child);
    offset += child.raw.length;
  }
  return result;
}
function oid(node: Der): string {
  const [first, ...rest] = node.content;
  const parts = [Math.floor(first / 40), first % 40];
  let value = 0;
  for (const byte of rest) {
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) { parts.push(value); value = 0; }
  }
  return parts.join('.');
}
function derTime(node: Der): number {
  const s = new TextDecoder().decode(node.content);
  const match = node.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s) : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s);
  if (!match) fail('Malformed certificate');
  const [y, ...rest] = match.slice(1).map(Number);
  return Date.UTC(node.tag === 0x17 ? (y >= 50 ? 1900 + y : 2000 + y) : y, rest[0] - 1, rest[1], rest[2], rest[3], rest[4]);
}
function equal(a: Uint8Array, b: Uint8Array) { return a.length === b.length && a.every((byte, i) => byte === b[i]); }
function pem(text: string) { return Uint8Array.from(atob(text.replace(/-----[^-]+-----|\s/g, '')), c => c.charCodeAt(0)); }
export function fromBase64(value: unknown, max = 65536): Uint8Array {
  if (typeof value !== 'string' || value.length > max || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) fail('Invalid base64');
  try { return Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)); } catch { return fail('Invalid base64'); }
}
export function toBase64(bytes: Uint8Array) { return btoa(String.fromCharCode(...bytes)); }
export async function sha256(...parts: Uint8Array[]) {
  const joined = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) { joined.set(part, offset); offset += part.length; }
  return new Uint8Array(await crypto.subtle.digest('SHA-256', joined));
}

interface Cert { tbs: Uint8Array; sigAlg: string; signature: Uint8Array; spki: Uint8Array; curve: string; point: Uint8Array; notBefore: number; notAfter: number; nonce?: Uint8Array }
function certificate(bytes: Uint8Array): Cert {
  const [tbs, alg, sig] = children(der(bytes));
  if (!tbs || !alg || !sig || tbs.tag !== 0x30 || sig.tag !== 0x03) fail('Malformed certificate');
  const fields = children(tbs);
  const at = fields[0].tag === 0xa0 ? 1 : 0;
  const validity = children(fields[at + 3]);
  const spki = fields[at + 5];
  const [algorithm, key] = children(spki);
  const [, curve] = children(algorithm);
  if (!curve || key.tag !== 0x03) fail('Malformed certificate');
  let nonce: Uint8Array | undefined;
  const extensions = fields.find(field => field.tag === 0xa3);
  if (extensions) {
    for (const extension of children(children(extensions)[0])) {
      const parts = children(extension);
      if (oid(parts[0]) !== nonceOID) continue;
      const [tagged] = children(der(parts[parts.length - 1].content));
      const [octets] = children(tagged);
      if (tagged.tag !== 0xa1 || octets?.tag !== 0x04) fail('Malformed nonce extension');
      nonce = octets.content;
    }
  }
  return { tbs: tbs.raw, sigAlg: oid(children(alg)[0]), signature: sig.content.subarray(1), spki: spki.raw, curve: oid(curve), point: key.content.subarray(1), notBefore: derTime(validity[0]), notAfter: derTime(validity[1]), nonce };
}
function rawSignature(signature: Uint8Array, size: number) {
  const [r, s] = children(der(signature));
  if (!r || !s || r.tag !== 0x02 || s.tag !== 0x02) fail('Malformed signature');
  const out = new Uint8Array(size * 2);
  for (const [i, part] of [r, s].entries()) {
    let value = part.content;
    while (value.length > size && value[0] === 0) value = value.subarray(1);
    if (value.length > size) fail('Malformed signature');
    out.set(value, i * size + size - value.length);
  }
  return out;
}
async function verifyCertSignature(cert: Cert, issuer: Cert) {
  const curve = curves[issuer.curve];
  const hash = hashes[cert.sigAlg];
  if (!curve || !hash) fail('Unsupported certificate algorithm');
  const key = await crypto.subtle.importKey('spki', issuer.spki, { name: 'ECDSA', namedCurve: curve.name }, false, ['verify']);
  if (!await crypto.subtle.verify({ name: 'ECDSA', hash }, key, rawSignature(cert.signature, curve.size), cert.tbs)) fail('Certificate chain is not trusted');
}

interface Cbor { [key: string]: Cbor | Cbor[] | Uint8Array | string | number }
function cbor(bytes: Uint8Array): Cbor {
  let offset = 0;
  const read = (depth: number): Cbor | Cbor[] | Uint8Array | string | number => {
    if (depth > 8 || offset >= bytes.length) fail('Malformed CBOR');
    const major = bytes[offset] >> 5;
    const info = bytes[offset++] & 31;
    let length = info;
    if (info >= 24) {
      const size = { 24: 1, 25: 2, 26: 4 }[info];
      if (!size || offset + size > bytes.length) fail('Malformed CBOR');
      length = 0;
      for (let i = 0; i < size; i++) length = length * 256 + bytes[offset++];
    }
    if (major === 0) return length;
    if (major === 2 || major === 3) {
      if (offset + length > bytes.length) fail('Malformed CBOR');
      const value = bytes.subarray(offset, offset + length);
      offset += length;
      return major === 2 ? value : new TextDecoder().decode(value);
    }
    if (major === 4) return Array.from({ length }, () => read(depth + 1)) as Cbor[];
    if (major === 5) {
      const map: Cbor = {};
      for (let i = 0; i < length; i++) {
        const key = read(depth + 1);
        if (typeof key !== 'string') fail('Malformed CBOR');
        map[key] = read(depth + 1);
      }
      return map;
    }
    return fail('Malformed CBOR');
  };
  const value = read(0);
  if (offset !== bytes.length || typeof value !== 'object' || Array.isArray(value) || value instanceof Uint8Array) fail('Malformed CBOR');
  return value;
}
function bytesField(map: Cbor, name: string): Uint8Array {
  const value = map[name];
  return value instanceof Uint8Array ? value : fail(`Missing ${name}`);
}

export async function verifyAttestation(attestation: Uint8Array, challenge: string, keyId: Uint8Array, appId: string, rootPem = appleRoot, now = Date.now()) {
  const object = cbor(attestation);
  const statement = object.attStmt;
  const chain = (statement && !Array.isArray(statement) && !(statement instanceof Uint8Array) && typeof statement === 'object' ? statement.x5c : undefined);
  if (object.fmt !== 'apple-appattest' || !Array.isArray(chain) || chain.length !== 2 || !chain.every(item => item instanceof Uint8Array)) fail('Unsupported attestation');
  const [leaf, intermediate] = (chain as Uint8Array[]).map(certificate);
  const root = certificate(pem(rootPem));
  await verifyCertSignature(leaf, intermediate);
  await verifyCertSignature(intermediate, root);
  for (const cert of [leaf, intermediate, root]) if (now < cert.notBefore - 300000 || now > cert.notAfter) fail('Certificate expired');
  const authData = bytesField(object, 'authData');
  const clientDataHash = await sha256(encoder.encode(challenge));
  if (!leaf.nonce || !equal(leaf.nonce, await sha256(authData, clientDataHash))) fail('Attestation nonce mismatch');
  if (leaf.curve !== '1.2.840.10045.3.1.7' || leaf.point.length !== 65 || !equal(await sha256(leaf.point), keyId)) fail('Key id mismatch');
  if (authData.length < 55) fail('Malformed authenticator data');
  if (!equal(authData.subarray(0, 32), await sha256(encoder.encode(appId)))) fail('Wrong app');
  if (new DataView(authData.buffer, authData.byteOffset).getUint32(33) !== 0) fail('Attestation counter must be zero');
  if (!aaguids.includes(new TextDecoder().decode(authData.subarray(37, 53)))) fail('Unsupported authenticator');
  const idLength = new DataView(authData.buffer, authData.byteOffset).getUint16(53);
  if (!equal(authData.subarray(55, 55 + idLength), keyId)) fail('Credential id mismatch');
  return leaf.point;
}

export async function verifyAssertion(assertion: Uint8Array, challenge: string, publicKey: Uint8Array, appId: string, counter: number) {
  const object = cbor(assertion);
  const authData = bytesField(object, 'authenticatorData');
  const signature = bytesField(object, 'signature');
  if (authData.length < 37 || !equal(authData.subarray(0, 32), await sha256(encoder.encode(appId)))) fail('Wrong app');
  const next = new DataView(authData.buffer, authData.byteOffset).getUint32(33);
  if (next <= counter) fail('Assertion replayed');
  const key = await crypto.subtle.importKey('raw', publicKey, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  const nonce = await sha256(authData, await sha256(encoder.encode(challenge)));
  if (!await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, rawSignature(signature, 32), nonce)) fail('Invalid assertion');
  return next;
}

async function mac(secret: string, message: string) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return toBase64(new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode('attest-challenge:' + message)))).replace(/[+/=]/g, c => ({ '+': '-', '/': '_', '=': '' })[c]!);
}
export async function makeChallenge(secret: string, now = Date.now()) {
  const nonce = crypto.randomUUID();
  const body = `${now}.${nonce}`;
  return `${body}.${await mac(secret, body)}`;
}
export async function checkChallenge(secret: string, value: unknown, now = Date.now()) {
  const match = typeof value === 'string' && value.length < 200 ? /^(\d{10,16})\.([0-9a-f-]{36})\.([A-Za-z0-9_-]+)$/.exec(value) : null;
  if (!match) return false;
  const issued = Number(match[1]);
  if (issued > now + 60000 || now - issued > 300000) return false;
  return equal(encoder.encode(await mac(secret, `${match[1]}.${match[2]}`)), encoder.encode(match[3]));
}
