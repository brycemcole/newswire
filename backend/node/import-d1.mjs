// Copies a D1 database into the Mini's SQLite. Export: on a machine with Wrangler access,
//   node node/import-d1.mjs export bryce-newswire dump.jsonl
// Import: on the Mini, with newswire-server stopped,
//   node node/import-d1.mjs import dump.jsonl ~/.local/share/newswire-server/newswire.sqlite
import { execFileSync } from 'node:child_process';
import { createReadStream, createWriteStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { DatabaseSync } from 'node:sqlite';

function query(database, sql) {
  const output = execFileSync('npx', ['wrangler', 'd1', 'execute', database, '--remote', '--json', '--command', sql], { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
  return JSON.parse(output)[0].results;
}

async function exportDatabase(database, file) {
  const out = createWriteStream(file);
  const tables = query(database, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'd1_%' AND name NOT LIKE '%_fts%' ORDER BY name").map(row => row.name);
  for (const table of tables) {
    // Forecast snapshots are up to 1.5 MB each, so that table pages slowly.
    const size = table === 'forecasts' ? 10 : 400;
    let rows = 0;
    for (let offset = 0; ; offset += size) {
      const page = query(database, `SELECT * FROM "${table}" ORDER BY rowid LIMIT ${size} OFFSET ${offset}`);
      for (const row of page) out.write(JSON.stringify({ table, row }) + '\n');
      rows += page.length;
      if (page.length < size) break;
    }
    console.log(`${table}: ${rows}`);
  }
  await new Promise(resolve => out.end(resolve));
}

async function importDatabase(file, target) {
  const db = new DatabaseSync(target);
  db.exec('PRAGMA journal_mode = WAL; BEGIN');
  const statements = new Map(), counts = {};
  for await (const line of createInterface({ input: createReadStream(file) })) {
    if (!line.trim()) continue;
    const { table, row } = JSON.parse(line);
    const columns = Object.keys(row);
    const key = `${table}|${columns.join(',')}`;
    if (!statements.has(key)) statements.set(key, db.prepare(`INSERT OR REPLACE INTO "${table}" (${columns.map(c => `"${c}"`).join(',')}) VALUES (${columns.map(() => '?').join(',')})`));
    statements.get(key).run(...columns.map(c => row[c]));
    counts[table] = (counts[table] ?? 0) + 1;
  }
  if (db.prepare("SELECT 1 FROM sqlite_master WHERE name='stories_fts'").get()) db.exec("INSERT INTO stories_fts (stories_fts) VALUES ('rebuild')");
  db.exec('COMMIT');
  console.log(counts);
}

const [mode, a, b] = process.argv.slice(2);
if (mode === 'export') await exportDatabase(a, b);
else if (mode === 'import') await importDatabase(a, b);
else throw new Error('Usage: import-d1.mjs export <database> <file> | import <file> <sqlite>');
