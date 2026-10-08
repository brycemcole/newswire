import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

// Keep in step with `shipAreas` in backend/src/data.ts: [[south, west], [north, east]].
const areas = {
  hormuz: [[25.0, 54.8], [27.6, 58.0]],
  'bab-el-mandeb': [[11.4, 42.3], [14.0, 44.6]],
  suez: [[29.3, 32.0], [31.6, 33.0]],
  malacca: [[0.5, 99.0], [4.8, 104.3]],
  panama: [[8.6, -80.2], [9.6, -79.3]],
  bosporus: [[40.8, 28.8], [41.4, 29.3]],
  taiwan: [[22.5, 117.8], [26.3, 121.4]],
  gibraltar: [[35.6, -6.3], [36.4, -4.9]],
};
const origin = process.env.NEWSWIRE_URL ?? 'https://bryce-newswire.bryce-e19.workers.dev';
const config = join(homedir(), '.config', 'newswire');
const keep = 6 * 3600000;
const ships = new Map();
const kinds = new Map();

export function kind(code) {
  if (code >= 80 && code <= 89) return 'Tanker';
  if (code >= 70 && code <= 79) return 'Cargo';
  if (code >= 60 && code <= 69) return 'Passenger';
  if (code === 30) return 'Fishing';
  if (code === 35) return 'Military';
  if (code === 31 || code === 32 || code === 52) return 'Tug';
  if (code >= 50 && code <= 59) return 'Service';
  if (code === 36 || code === 37) return 'Pleasure';
  return 'Other';
}

export function areaOf(lat, lon) {
  return Object.entries(areas).find(([, [[south, west], [north, east]]]) => lat >= south && lat <= north && lon >= west && lon <= east)?.[0];
}

export function absorb(message) {
  const meta = message.MetaData ?? {};
  const mmsi = String(meta.MMSI ?? '');
  if (!mmsi) return;
  if (message.MessageType === 'ShipStaticData') {
    kinds.set(mmsi, kind(Number(message.Message?.ShipStaticData?.Type)));
    return;
  }
  const report = message.Message?.PositionReport;
  if (!report) return;
  const lat = Number(report.Latitude ?? meta.latitude), lon = Number(report.Longitude ?? meta.longitude);
  const area = areaOf(lat, lon);
  if (!area) return;
  const speed = Number(report.Sog), course = Number(report.TrueHeading) < 360 ? Number(report.TrueHeading) : Number(report.Cog);
  ships.set(mmsi, { area, mmsi, name: String(meta.ShipName ?? '').trim().slice(0, 40), lat, lon,
    speed: Number.isFinite(speed) && speed < 102.3 ? speed : 0, course: Number.isFinite(course) && course < 360 ? course : 0, at: new Date().toISOString() });
}

async function flush(bearer) {
  const cutoff = Date.now() - keep;
  for (const [mmsi, ship] of ships) if (Date.parse(ship.at) < cutoff) ships.delete(mmsi);
  for (const area of Object.keys(areas)) {
    const list = [...ships.values()].filter(ship => ship.area === area).slice(0, 1500).map(({ area: _, ...ship }) => ({ ...ship, kind: kinds.get(ship.mmsi) ?? 'Other' }));
    const response = await fetch(new URL('/v1/ships', origin), { method: 'POST', headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ area, ships: list }), signal: AbortSignal.timeout(20000) }).catch(error => ({ ok: false, status: error.message }));
    if (!response.ok) console.error(`ships ${area}: ${response.status}`);
  }
  console.log(JSON.stringify({ at: new Date().toISOString(), ships: ships.size, byArea: Object.fromEntries(Object.keys(areas).map(a => [a, [...ships.values()].filter(s => s.area === a).length])) }));
}

async function main() {
  const key = (await readFile(join(config, 'aisstream.key'), 'utf8').catch(() => '')).trim();
  if (!key) {
    console.log(`No AISStream key. Create one at https://aisstream.io and save it to ${join(config, 'aisstream.key')}, then restart newswire-ships.`);
    return;
  }
  const bearer = (await readFile(join(config, 'writer-token'), 'utf8')).trim();
  const timer = setInterval(() => flush(bearer).catch(error => console.error(`flush: ${error.message}`)), 180000);
  await new Promise((resolve, reject) => {
    const socket = new WebSocket('wss://stream.aisstream.io/v0/stream');
    socket.addEventListener('open', () => socket.send(JSON.stringify({ APIKey: key, BoundingBoxes: Object.values(areas), FilterMessageTypes: ['PositionReport', 'ShipStaticData'] })));
    socket.addEventListener('message', event => {
      try { absorb(JSON.parse(typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString())); } catch {}
    });
    socket.addEventListener('close', event => reject(new Error(`AISStream closed ${event.code} ${event.reason}`)));
    socket.addEventListener('error', () => reject(new Error('AISStream connection error')));
  }).finally(() => clearInterval(timer));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(error => { console.error(error.message); process.exit(1); });
}
