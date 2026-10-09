# Newswire API v1

Private news wire backed by Cloudflare Workers + D1. All story reads require a bearer token: an App Attest session token (see Attestation) or the writer token. All writes require the writer token. Tokens never belong in query strings or app bundles.

Live origin: https://bryce-newswire.bryce-e19.workers.dev. Machine-readable input schema: /story.schema.json.

## Story contract

```json
{
  "external_id": "agent-a:source-unique-id",
  "title": "Headline in plain language",
  "summary": "Concise factual summary with attribution.",
  "body": "Optional longer report; plain text or simple HTML (p, br, h1-h6, ul/ol/li, blockquote, pre, hr, a, strong/em/u/s/code). Readers render the supported subset natively; unsupported tags are ignored and their text kept.",
  "source": "Publisher or primary source",
  "url": "https://example.com/original-story",
  "published_at": "2026-09-06T14:30:00Z",
  "category": "technology",
  "priority": "normal",
  "tickers": ["AAPL"],
  "tags": ["ai"],
  "agent": "agent-a"
}
```

Required: external_id (1–200), title (1–300), source (1–100), url (absolute HTTP/S), published_at (ISO 8601 with timezone). Optional: summary (default empty, max 2000), body (default empty, max 20000), category (default general; general/markets/technology/economy/politics/world/science), priority (normal/urgent/breaking; default normal), tickers (max 20 strings, each max 20), tags (max 20 strings, each max 40), agent (default unknown, max 100). No future timestamps beyond five minutes. Server adds id (UUID), received_at (UTC ISO 8601), retracted_at (null until a writer retracts the story), normalizes published_at to UTC ISO 8601 with milliseconds. Unknown fields rejected.

## Routes

- GET /health → {"ok":true,"version":1}
- GET /v1/stories?limit=50&cursor=OPAQUE&category=technology&q=search&priority=breaking&ticker=AAPL&tag=ai&agent=agent-a&source=Reuters&since=ISO&until=ISO&retracted=exclude → {"stories":[Story],"next_cursor":string|null}. Limit 1–100. Optional filters: category, priority, ticker, tag, agent, source (exact match), q (substring search), since/until (published_at window, inclusive, ISO 8601). retracted controls tombstones: exclude (default), include, or only. Order published_at DESC, id DESC. Cursor encodes last timestamp/id; clients treat it as opaque. New stories arrive at top, older stories load downwards.
- GET /v1/stories/:id → {"story":Story}. Resolves retracted stories too, with retracted_at set.
- DELETE /v1/stories/:id (writer only) → 200 {"story":Story,"retracted":bool}. Retraction tombstone: sets retracted_at, hides the story from default listings, and never edits or deletes content. Idempotent — retracting again returns retracted:false. Session tokens receive 403; unknown ids 404.
- POST /v1/stories with one JSON Story input → 201 {"story":Story,"duplicate":false}; repeated external_id or normalized URL returns existing story and 200 {"story":Story,"duplicate":true}. No overwriting.
- POST /v1/devices {"token":hex,"environment":"sandbox"|"production"} (session or writer) → 201 {"registered":true}. Upserts an APNs device token. GET /v1/devices (writer only) → {"devices":[{token,environment}]}. DELETE /v1/devices/:token (writer only) → {"removed":bool}.
- GET /v1/ingest with the same fields as URL-encoded query parameters. tickers/tags are comma-separated. Same auth and result as POST. Explicit ingestion route only; GET /v1/stories never writes. Ingest responses always no-store. GET URL capped at 8000 bytes; use POST for longer text.
- OPTIONS supported. Errors: {"error":{"code":string,"message":string}} with 400/401/403/404/405/413/500/503.

## Data routes

`GET /v1/data/*` is one read-only data layer for the apps, the chat and outside agents. It needs a reader or writer bearer token. Every response has the same shape: `title`, `source`, `url`, `as_of`, an optional `note`, `sections` of rows (`label`, `value`, optional `change`, `change_label`, `date`, `symbol`, `series`, `story`, `url`, `points`), an optional `chart`, and `text`, a plain-text rendering meant for a model. Nothing is computed that the upstream source did not provide.

`GET /v1/data/tools.json` lists every tool with its name, path, description and JSON Schema parameters. Call a tool by path (`/v1/data/fed/odds`, `/v1/data/series/UNRATE`, `/v1/data/board/fx`) or by name (`/v1/data/tool/fed_odds`). Adding a tool to `backend/src/data.ts` publishes it to the iOS chat, the catalog and MCP at once.

| Tool | Path | Source |
|---|---|---|
| `macro` | `macro?group=fed\|jobs\|inflation\|growth\|rates\|credit\|global\|prices` | FRED |
| `series`, `series_search` | `series/:id`, `series/search?q=` | FRED (full search needs `FRED_API_KEY`) |
| `calendar` | `calendar?days=7&impact=medium&countries=USD,JPY&upcoming=true` | ForexFactory week (forecast, previous), BLS schedule, FOMC calendar |
| `releases` | `releases?days=45&impact=high` | FRED actuals plus archived Nasdaq actual/consensus/previous |
| `economic_history` | `economic/history?q=CPI&days=60&countries=USD` | Archived Nasdaq reported releases; duplicate labels can omit periodicity |
| `source_search` | `sources/search?q=payrolls` | Recently collected public Google News coverage; discovery excerpts |
| `fed_odds` | `fed/odds` | Fed funds futures (Yahoo), EFFR (FRED) |
| `yield_curve` | `yields?region=us\|euro\|japan` | US Treasury, ECB, Japan Ministry of Finance |
| `board` | `board/world\|fx\|commodities\|rates` | Yahoo Finance |
| `quote`, `symbol_search`, `screener` | `quote?symbols=`, `symbols?q=`, `screener?region=jp&max_pe=15` | Yahoo Finance |
| `stock_history` | `stock/history?symbol=BB&period=ytd` | Yahoo Finance chart; price return excludes dividends |
| `stock_fundamentals` | `stock/fundamentals?symbol=BB` | Yahoo Finance quote summary and reported-quarter history; no management guidance |
| `stock_news` | `stock/news?symbol=BB&company=BlackBerry&days=180` | Yahoo Finance public headlines matched to ticker |
| `wire_search` | `wire/search?q=&days=30` | D1 full-text index (`stories_fts`) |
| `sec_filings`, `insider_trades`, `holders` | `sec/filings?symbol=`, `sec/insiders?symbol=`, `sec/holders?symbol=` | SEC EDGAR, Yahoo (13F) |
| `contracts` | `contracts?company=` | USAspending, falling back to FPDS |
| `chokepoints` | `chokepoints?name=` | IMF PortWatch |
| `ships` | `ships?area=hormuz` | AISStream positions posted by the Mac mini (`scripts/ships`) |
| `world_economy` | `world?indicator=gdp&countries=JPN,DEU` | IMF DataMapper |

Yahoo endpoints are unofficial and may break or rate limit; the government sources are official. Quotes are cached at the edge for 20 seconds, stock news for 10 minutes, fundamentals for 30 minutes, and price history for 5 minutes; calendars are cached for up to a day.

Writer-only feeds into this layer: `POST /v1/econ/events` (the monitor posts ForexFactory's week hourly, because the feed rate-limits Cloudflare) and `POST /v1/ships` (`{area, ships: [{mmsi, name, kind, lat, lon, speed, course, at}]}` from the ship stream). `POST /v1/devices` also takes `muted_topics`, the notification topics the device has turned off (see `topics` in `scripts/monitor/apns.mjs`).

`POST /v1/mcp` serves the same tools as a Model Context Protocol server (JSON-RPC over streamable HTTP: `initialize`, `tools/list`, `tools/call`). Point an MCP client at `https://bryce-newswire.bryce-e19.workers.dev/v1/mcp` with an `Authorization: Bearer` header.

Optional secret: `wrangler secret put FRED_API_KEY` (free from fred.stlouisfed.org) enables FRED's full series search, series metadata and the wider release calendar.

## Brain routes

The Worker also binds the Brain app's D1 database (`BRAIN`) and Workers AI (`AI`). Brain posts are served in the Story shape above with `agent: "brain"`, `external_id: "brain:<id>"`, a derived title when the post has none, and an extra `interaction` field (`like`, `dislike`, `save`, or null). Posts without an HTTP source link are omitted.

- GET /v1/brain/stories?limit&cursor&category&priority&tag&source&q&since&until (reader) → {"stories":[Story],"next_cursor"}. Newest first by the post's created_at. Brain categories map onto wire categories (AI/Tech/Security → technology, Macro → economy, Markets/Crypto → markets, Biotech/Science/Papers → science); priority 10 is breaking and 8-9 urgent.
- GET /v1/brain/stories/:id (reader). POST /v1/brain/stories/:id/view (reader) sets viewed_at, as the Brain app does. POST /v1/brain/stories/:id/interaction {"type":"like"|"dislike"|"save"|"none"} (reader) replaces the post's interaction and returns the updated story.
- POST /v1/brain/posts {"posts":[...]} (writer, 1-50) inserts posts with content, source_url, and optional title, summary, body, source, source_type, category, priority (1-10), created_at, image_url. Existing source URLs are skipped → {"inserted","duplicates"}.
- POST /v1/brain/known {"urls":[...]} (writer) → {"known":[...]}. GET /v1/brain/taste (writer) → recent likes/saves/dislikes and titles from the last 48 hours.
- POST /v1/brain/ai {"messages":[...],"max_tokens","model"} (writer) runs a Workers AI model (`@cf/...`) and returns {"text","model","usage"}.

Brain schema changes live in `backend/brain/` and apply with `npx wrangler d1 migrations apply brain --remote`.

Authorization: Bearer TOKEN. Cloudflare secret WRITER_TOKEN (also signs attestation challenges). Session tokens cannot ingest. Missing secret fails closed. Static web shell may be public, all story data private.

## Agent example

```sh
curl --get "$NEWSWIRE_URL/v1/ingest" \
  --header "Authorization: Bearer $NEWSWIRE_WRITER_TOKEN" \
  --data-urlencode 'external_id=agent-a:example-001' \
  --data-urlencode 'title=Example headline' \
  --data-urlencode 'source=Example publisher' \
  --data-urlencode 'url=https://example.com/story-001' \
  --data-urlencode 'published_at=2026-09-06T14:30:00Z' \
  --data-urlencode 'category=technology' \
  --data-urlencode 'summary=Attributed summary.' \
  --data-urlencode 'agent=agent-a'
```

Use the original publication timestamp and original source URL. Reuse external_id when retrying. Retry 429/5xx with exponential backoff; fix 4xx payload/auth errors. Do not invent headlines or present synthetic examples as real news. GET ingestion is intended for agents, never embed ingestion URLs as browser links because link scanners can invoke them.

## Attestation (iOS sign-in)
The app generates a Secure Enclave key with Apple App Attest; no token is typed or shipped. Endpoints are unauthenticated.
- GET /v1/attest/challenge → {"challenge"}. Stateless, HMAC-signed with WRITER_TOKEN, valid 5 minutes.
- POST /v1/attest {"key_id","attestation","challenge"} (base64) → 201 {"token","expires_at"}. Verifies Apple's attestation (certificate chain to the App Attest root, nonce, key id, app id `ATTEST_APP_ID` default `A792L5W262.com.brycecole.newswire`, counter 0), stores the public key, mints a 7-day session token.
- POST /v1/attest/session {"key_id","assertion","challenge"} → 201 {"token","expires_at"}. Renews with a signed assertion; the counter must increase. Unknown key 404 (`unknown_key`), bad proof 401 (`attestation_failed`).
Session tokens are random, stored only as SHA-256, and read-only (403 on writer routes). `ATTEST_ROOT_CA` overrides the pinned Apple root and exists for tests.

The monitor syncs the current calendar, historical releases, six years of curated FRED observations, and public economic coverage hourly. Writer-only `POST /v1/econ/history` takes `{date, rows}`; `POST /v1/econ/series` takes `{id, observations}`; `POST /v1/econ/sources` takes `{rows}`. FRED snapshots collected within the last hour serve curated series promptly. Older snapshots are used only when live access fails, marked with collector time and rejected after seven days. Public coverage is rejected after two days. Snapshots preserve published actual/forecast/previous independently; ambiguous provider labels must not be guessed as monthly or yearly. The default releases window is 45 days so monthly jobs and CPI remain visible after the week changes.
