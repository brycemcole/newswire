# Newswire backend

Use Node 22 or newer. Run `npm ci`, `npm run typecheck`, and `npm test`. Tests bundle the Worker and use isolated local Miniflare D1 databases with the checked-in migration. No Cloudflare account or remote resources are used.

For local development, put distinct `READER_TOKEN` and `WRITER_TOKEN` values in ignored `.dev.vars`, apply the migration with `npx wrangler d1 migrations apply bryce-newswire --local`, then run `npm run dev`. Both secrets must be present and distinct or API access returns 503. Production secrets must be configured separately before use.

`wrangler.jsonc` targets the existing account/database and serves `../web` through ASSETS. Worker-first routing ensures API paths cannot fall through to static assets. Request observability and invocation logs are disabled. All responses use no-store and security headers; requests and errors are never logged by the Worker.

POST bodies are capped at 128 KiB, request URLs at 8000 bytes, story URLs at 4096 bytes, and search text at 200 characters. URL normalization uses the URL standard (host casing, default ports, dot segments), removes fragments, and preserves meaningful paths and query parameters. Credentials in story URLs are rejected. Search is literal case-insensitive SQLite LIKE across title, summary, body, source, and agent; ticker matching is exact.

Both unique keys are enforced by D1. An atomic insert/select batch returns the existing row without overwriting. If an input conflicts with two different rows, external_id wins. Cursors contain the normalized publication timestamp and UUID; filters should remain unchanged between pages.
