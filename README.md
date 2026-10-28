# Newswire

A private, terminal-inspired news wire: Cloudflare Workers + D1, a web terminal, and a native SwiftUI iOS reader. Newest publication timestamps appear first; scroll down to load earlier reports. No market quotes are invented.

Live origin: https://bryce-newswire.bryce-e19.workers.dev

Verified 2026-09-07: backend typecheck and all 15 Miniflare tests pass, including the retraction tombstone and the new list filters; the monitor's 20 rules were exercised against live sources with `--dry-run` (no failures). Not yet deployed: the next `wrangler deploy` from backend must be preceded by `wrangler d1 migrations apply` to ship `0002_retracted_at`.

Machine-readable agent contract: [story.schema.json](web/story.schema.json).

## Deterministic monitor

A rules engine publishes market, macro, fiscal, earnings, Treasury auction, disaster, policy, infrastructure, and watched-headline alerts from public data on a three-minute schedule, with Jev classifying watched headlines and no model elsewhere, plus one daily digest of everything the wire published. Thresholds, sources, deduplication, and the launchd agent are documented in [MONITOR.md](MONITOR.md).

## Agent integration

## DeepSeek

Newswire calls the DeepSeek API directly (`deepseek-flash`, thinking disabled) with the key from `DEEPSEEK_API_KEY`, `DEEPSEEK_API_KEY_FILE`, `~/.config/newswire/deepseek-key` or `~/.kalshi/deepseek.key`. `scripts/ai/deepseek.mjs` is the shared client. An authenticated, bounded in-memory queue in a dedicated Compute Durable Object connects iOS requests to the worker on the Mini; requests expire after 85 seconds and are not stored in D1.

Ask, article summaries, move explanations, and market starter questions use the shared iOS router. Apple on-device inference and a personal DeepSeek API key remain selectable in AI settings. Background research answers, scored index predictions, headline/impact classification, and Brain selection/writing also use DeepSeek. Prices, market data, forecast settlement, and deterministic alerts remain grounded in their existing data sources.

Every story reader also offers Market, Stocks, and Watch lenses plus article-specific Ask questions. Lenses describe possible transmission channels and missing evidence, verify suggested ticker/company matches against quotes, and label indirect exposures separately from companies mentioned in the story. Questions carry the source text and publication time into Ask and remain attached when a chat is reopened. The analysis is generated only for opened stories, coalesced and cached locally for seven days with an 80-story limit, and refreshed when source content changes. It never rewrites source tickers, alerts, holdings, or the quantitative forecast.

Copy `scripts/ai/` alongside the other deployed scripts, install `scripts/ai/newswire-ai.service` under `~/.config/systemd/user/`, and run `systemctl --user daemon-reload && systemctl --user enable --now newswire-ai`. It reuses the host's protected Newswire writer token and DeepSeek key.

`GET /v1/ai/status` reports runtime availability; `POST /v1/ai/chat/completions` accepts authenticated app requests. Only the writer can claim or complete jobs under `/v1/ai/worker/`. Background tasks call the same client directly. `NEWSWIRE_CLASSIFIER_PROVIDER=jev` is an explicit override that classifies with OpenCode Zen's Jev instead of DeepSeek.

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

## Shake to report

Shake the phone anywhere in the app to send a bug report or feature request. The sheet attaches a screenshot of the current screen, takes up to three more from Photos, and sends them with the app version, build, iOS version and device model to `POST /v1/feedback` (reader session; JPEGs under 1 MB each, at most four). Reports wait in D1 (`feedback`, `feedback_images`) with status `new`.

On the Mini, `newswire-feedback.timer` runs `scripts/feedback/run.mjs` every two minutes. It claims one report (`new` → `working`, so two runs never take the same one), writes the screenshots to `~/.cache/newswire-feedback`, makes a worktree of `origin/main` in `~/feedback`, and runs `claude -p` on it (`NEWSWIRE_FIX_AGENT=codex` uses `codex exec` instead). If the agent changed files, it commits them on `feedback/<kind>-<id>`, pushes, opens a draft PR, marks the report `done` with the PR link and pushes a notification to the phone that sent it. No changes or an error mark it `failed` with the agent's explanation. The agent cannot build iOS on Linux, so SwiftUI changes are only checked by the PR's CI job.

If `~/.config/newswire/asc.json` (`key_id`, `issuer_id`) and `asc-key.p8` exist, the same run also imports TestFlight's own screenshot feedback into the queue.

Setup on the Mini: a fine-grained GitHub token for this repository with Contents and Pull requests read/write in `~/.config/newswire/github-token` (mode 600), `claude` (or `codex`) signed in, then copy the two units from `scripts/feedback/` to `~/.config/systemd/user/` and `systemctl --user enable --now newswire-feedback.timer`. Logs: `journalctl --user -u newswire-feedback`.

## Architecture

Agents → authenticated ingestion → Worker → D1 → authenticated feed → iOS / web.

The ingestion API accepts reports; it does not schedule agents or autonomously scrape publishers. GET ingestion must be called deliberately by an agent, never embedded in browser links or images. Prefer POST for long text. Feed pagination uses a timestamp/ID cursor so new arrivals do not shift the older pages. Story content is immutable; the only mutation is a writer-authenticated retraction tombstone (`DELETE /v1/stories/:id`), which hides a story from default listings without editing or deleting it. Duplicate submissions return the stored report.

The implementation follows Cloudflare's [D1 setup](https://developers.cloudflare.com/d1/get-started/) and [migration workflow](https://developers.cloudflare.com/d1/reference/migrations/).
