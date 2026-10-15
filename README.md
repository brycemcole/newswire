# Newswire

A private, terminal-inspired news wire: Cloudflare Workers + D1, a web terminal, and a native SwiftUI iOS reader. Newest publication timestamps appear first; scroll down to load earlier reports. No market quotes are invented.

Live origin: https://bryce-newswire.bryce-e19.workers.dev

Verified 2026-09-07: backend typecheck and all 15 Miniflare tests pass, including the retraction tombstone and the new list filters; the monitor's 20 rules were exercised against live sources with `--dry-run` (no failures). Not yet deployed: the next `wrangler deploy` from backend must be preceded by `wrangler d1 migrations apply` to ship `0002_retracted_at`.

Machine-readable agent contract: [story.schema.json](web/story.schema.json).

## Deterministic monitor

A rules engine publishes market, macro, fiscal, earnings, Treasury auction, disaster, policy, infrastructure, and watched-headline alerts from public data on a three-minute schedule, with Jev classifying watched headlines and no model elsewhere, plus one daily digest of everything the wire published. Thresholds, sources, deduplication, and the launchd agent are documented in [MONITOR.md](MONITOR.md).

## Agent integration

## Free DeepSeek

Newswire defaults to `deepseek-v4.1-flash-free` (200,000-token context) through the official OpenCode runtime. OpenCode rejects direct API use of its free tier. The unmodified runtime runs on the Mini; an authenticated, bounded in-memory queue in a dedicated Compute Durable Object connects iOS requests to it. Requests expire after 85 seconds and are not stored in D1. The app AI worker tries the free runtime for up to 12 seconds, then falls back to `deepseek-v4.1-flash` through OpenCode Go within the existing 75-second generation budget. Go uses `NEWSWIRE_GO_API_KEY` when set, otherwise the Mini’s existing OpenCodex Go credential. Responses identify Go and subscription billing; the fallback never uses the pay-as-you-go endpoint. Background jobs that call the free runtime directly retain their existing behavior.

Ask, article summaries, move explanations, and market starter questions use the shared iOS router. Apple on-device inference and a personal DeepSeek API key remain selectable in AI settings. Background research answers, scored index predictions, headline/impact classification, and Brain selection/writing also use the free runtime. Prices, market data, forecast settlement, and deterministic alerts remain grounded in their existing data sources.

Every story reader also offers Market, Stocks, and Watch lenses plus article-specific Ask questions. Lenses describe possible transmission channels and missing evidence, verify suggested ticker/company matches against quotes, and label indirect exposures separately from companies mentioned in the story. Questions carry the source text and publication time into Ask and remain attached when a chat is reopened. The analysis is generated only for opened stories, coalesced and cached locally for seven days with an 80-story limit, and refreshed when source content changes. It never rewrites source tickers, alerts, holdings, or the quantitative forecast.

Install the runtime on the host with `npm install --prefix ~/.local/share/newswire/opencode opencode-ai@1.19.0`. Copy `scripts/ai/` alongside the other deployed scripts, install `scripts/ai/newswire-ai.service` under `~/.config/systemd/user/`, and run `systemctl --user daemon-reload && systemctl --user enable --now newswire-ai`. It reuses the host's protected Newswire writer token. The OpenCode runtime uses its own isolated config/data directories and requires no paid key. `NEWSWIRE_OPENCODE_BIN` and `NEWSWIRE_OPENCODE_HOME` override its paths.

`GET /v1/ai/status` reports runtime availability; `POST /v1/ai/chat/completions` accepts authenticated app requests. Only the writer can claim or complete jobs under `/v1/ai/worker/`. Background tasks call the same local adapter directly. Explicit legacy overrides are `NEWSWIRE_AGENT_PROVIDER=go|zen` and `NEWSWIRE_CLASSIFIER_PROVIDER=jev`; these can incur charges and are never automatic fallbacks. Free availability and provider rate limits can change.

## Brain mode

The brain button at the top left of the iOS home screen switches between the wire and the Brain app's feed, read from the same D1 database the Brain app uses. Brain stories open in the reader, and the thumbs menu in a story records like, save, or less-like-this signals back into Brain's taste data.

`scripts/brain/scrape.mjs` runs on the Mac mini every 20 minutes (`~/.config/systemd/user/newswire-brain.{service,timer}`, logs in `journalctl --user -u newswire-brain`). It pulls recent arXiv cs.AI/cs.LG/cs.CL/cs.CV submissions, Hugging Face Daily Papers, and Hacker News front-page items above 150 points; scores them against Brain likes, saves, and dislikes with free DeepSeek through OpenCode; and queues items scoring 8 or more. For each published paper it reads the arXiv HTML version, falling back to the PDF and then the abstract, and writes a plain-English title, takeaway, summary, and key points. The original title and source are kept in the body. Defaults: 5 posts per run, 24 per day (`BRAIN_PER_RUN`, `BRAIN_DAILY_MAX`, `BRAIN_MIN_SCORE`). State lives in `~/.config/newswire/brain-state.json`. Deploy with `rsync -a --exclude node_modules scripts/brain/ mini:newswire/scripts/brain/` and `npm install` in that directory. `--dry-run` writes without inserting.

## Agent API

See [API.md](API.md) for the canonical story format, required fields, authenticated GET ingestion, JSON POST, filters, retry behavior, and deduplication. Give agents the backend URL and a writer token; the iOS app needs no token: it authenticates with App Attest (see [API.md](API.md)). Source links and stable external IDs prevent accidental duplicate submissions.

Upload a story from this Mac:

```sh
NEWSWIRE_URL=https://bryce-newswire.bryce-e19.workers.dev node scripts/upload-story.mjs story.json --get
```

Omit `--get` to send JSON POST. The helper uses the writer credential from macOS Keychain, or `NEWSWIRE_WRITER_TOKEN` on another host. It does not print credentials.

## Credentials

`node scripts/provision-secrets.mjs` provisions the writer credential in Cloudflare and macOS Keychain, service `com.brycecole.newswire`, account `writer`. Existing Keychain values are reused on reruns. Use Keychain Access to retrieve/share the appropriate credential privately. No credential is included in the repository or iOS bundle. The web reader takes the writer token and keeps it in memory for the current tab only; the iOS app holds a Secure Enclave key and a short-lived session token in Keychain.

## Portfolio (Plaid)

The iOS Portfolio tab syncs brokerage positions through Plaid using keys you enter in the app (kept in iCloud Keychain, never in this repo). Setup steps are in [PLAID.md](PLAID.md).

## Local development

Backend: `cd backend`, `npm install`, `npm test`, and `npm run dev`. Use local `.dev.vars` for WRITER_TOKEN (ignored by Git). Apply D1 migrations locally before development. Cloudflare deployment requires Wrangler login, remote migrations, and `wrangler deploy` from backend.

iOS: `cd ios`, `xcodegen generate`, then open `Newswire.xcodeproj`. Build with Xcode beta. Configure the HTTPS backend URL in the app. Physical-device signing and distribution are separate from Simulator validation.

## CI and TestFlight

`Newswire.xcodeproj` is generated and not committed; `ios/project.yml` is authoritative. Pull requests run backend typecheck/tests and iOS unit tests (`.github/workflows/ci.yml`). Merges to `main` that touch `ios/` archive a Release build on GitHub's `xcode-27` runner and upload it to TestFlight (`.github/workflows/testflight.yml`); it can also be started manually from the Actions tab. Signing is cloud-managed through the App Store Connect API key in repository secrets `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and `APP_STORE_CONNECT_PRIVATE_KEY`. Build numbers derive from the workflow run; bump `MARKETING_VERSION` in `project.yml` for a new release version. `ios/scripts/release.sh` remains the local ad hoc path.

## Architecture

Agents → authenticated ingestion → Worker → D1 → authenticated feed → iOS / web.

The ingestion API accepts reports; it does not schedule agents or autonomously scrape publishers. GET ingestion must be called deliberately by an agent, never embedded in browser links or images. Prefer POST for long text. Feed pagination uses a timestamp/ID cursor so new arrivals do not shift the older pages. Story content is immutable; the only mutation is a writer-authenticated retraction tombstone (`DELETE /v1/stories/:id`), which hides a story from default listings without editing or deleting it. Duplicate submissions return the stored report.

The implementation follows Cloudflare's [D1 setup](https://developers.cloudflare.com/d1/get-started/) and [migration workflow](https://developers.cloudflare.com/d1/reference/migrations/).
