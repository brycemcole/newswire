Newswire production runs on the Mini as `newswire-server.service`, using Node 22 SQLite databases in `~/.local/share/newswire-server/`. The deployed files are in `~/newswire-server/`; ingestion and AI jobs remain in `~/newswire/`.

The existing `bryce-newswire` Worker forwards database-backed routes through the `newswire-mini` Cloudflare Tunnel to the Mini. `ORIGIN_URL` and `ORIGIN_TOKEN` are Worker secrets. The tunnel forces its origin Host header, and the server checks the shared origin token for tunnel requests. Loopback jobs retain bearer authentication. `/__cron` is blocked at the public forwarding entry point. `/v1/brain/ai` remains on Workers AI and does not use D1 with the server credential.

Build the server bundle from `backend/` with Node 22:

```sh
./node_modules/.bin/esbuild src/index.ts --bundle --format=esm --outfile=node/worker.mjs
npm run typecheck
node --test test/free-ai.test.mjs
```

Copy the bundle and `node/server.mjs` to the Mini's deployment directory, then restart `newswire-server`. Tunnel configuration and credentials live outside the repository in `~/.config/newswire-tunnel/`. The origin secret is in `~/.config/newswire-server.env`. Both services are enabled at boot with user lingering.

`newswire-backup.timer` runs `node/backup.py` daily; it uses SQLite's backup API, checks integrity, and retains 14 snapshots. The migration's original exports and pre-import snapshots remain in `~/.local/share/newswire-server/migration-backup/`. Cloudflare D1 databases remain untouched as pre-cutover recovery copies; they are no longer current. Reverting to them without syncing new local writes would lose post-cutover changes.

After changes, run `node scripts/smoke/check.mjs --no-alert --all` from `~/newswire` on the Mini. Also verify a short-lived reader session through the public URL for feed, Brain, and `/v1/ai/chat/completions`, then remove the diagnostic session. Writer credentials skip the reader-session lookup and cannot prove that path.
