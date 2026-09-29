# Newswire

A private, terminal-inspired news wire: Cloudflare Workers + D1, a web terminal, and a native SwiftUI iOS reader. Newest publication timestamps appear first; scroll down to load earlier reports. No market quotes are invented.

Live origin: https://bryce-newswire.bryce-e19.workers.dev

Verified 2026-09-07: backend typecheck and all 15 Miniflare tests pass, including the retraction tombstone and the new list filters; the monitor's 20 rules were exercised against live sources with `--dry-run` (no failures). Not yet deployed: the next `wrangler deploy` from backend must be preceded by `wrangler d1 migrations apply` to ship `0002_retracted_at`.

Machine-readable agent contract: [story.schema.json](web/story.schema.json).

## Deterministic monitor

A rules engine publishes market, macro, fiscal, earnings, Treasury auction, disaster, policy, infrastructure, and watched-headline alerts from public data on a three-minute schedule, with Jev classifying watched headlines and no model elsewhere, plus one daily digest of everything the wire published. Thresholds, sources, deduplication, and the launchd agent are documented in [MONITOR.md](MONITOR.md).

## Agent integration

## Brain mode

The brain button at the top left of the iOS home screen switches between the wire and the Brain app's feed, read from the same D1 database the Brain app uses. Brain stories open in the reader, and the thumbs menu in a story records like, save, or less-like-this signals back into Brain's taste data.

`scripts/brain/scrape.mjs` runs on the Mac mini every 20 minutes (`~/.config/systemd/user/newswire-brain.{service,timer}`, logs in `journalctl --user -u newswire-brain`). It pulls recent arXiv cs.AI/cs.LG/cs.CL/cs.CV submissions, Hugging Face Daily Papers, and Hacker News front-page items above 150 points; scores them against Brain likes, saves, and dislikes with Workers AI (`@cf/openai/gpt-oss-120b`); and queues items scoring 8 or more. For each published paper it reads the arXiv HTML version, falling back to the PDF and then the abstract, and writes a plain-English title, takeaway, summary, and key points. The original title and source are kept in the body. Defaults: 5 posts per run, 24 per day (`BRAIN_PER_RUN`, `BRAIN_DAILY_MAX`, `BRAIN_MIN_SCORE`). State lives in `~/.config/newswire/brain-state.json`. Deploy with `rsync -a --exclude node_modules scripts/brain/ mini:newswire/scripts/brain/` and `npm install` in that directory. `--dry-run` writes without inserting.

## Agent API

See [API.md](API.md) for the canonical story format, required fields, authenticated GET ingestion, JSON POST, filters, retry behavior, and deduplication. Give agents the backend URL and a writer token; give readers only the reader token. Source links and stable external IDs prevent accidental duplicate submissions.

Upload a story from this Mac:

```sh
NEWSWIRE_URL=https://bryce-newswire.bryce-e19.workers.dev node scripts/upload-story.mjs story.json --get
```

Omit `--get` to send JSON POST. The helper uses the writer credential from macOS Keychain, or `NEWSWIRE_WRITER_TOKEN` on another host. It does not print credentials.

## Credentials

`node scripts/provision-secrets.mjs` provisions separate reader/writer credentials in Cloudflare and macOS Keychain, service `com.brycecole.newswire`, accounts `reader` and `writer`. Existing Keychain values are reused on reruns. Use Keychain Access to retrieve/share the appropriate credential privately. No credential is included in the repository or iOS bundle. Web reader credentials last only for the current tab; the iOS app stores its reader token in Keychain.

## Local development

Backend: `cd backend`, `npm install`, `npm test`, and `npm run dev`. Use local `.dev.vars` for READER_TOKEN and WRITER_TOKEN (ignored by Git). Apply D1 migrations locally before development. Cloudflare deployment requires Wrangler login, remote migrations, and `wrangler deploy` from backend.

iOS: `cd ios`, `xcodegen generate`, then open `Newswire.xcodeproj`. Build with Xcode beta. Configure the HTTPS backend URL and reader token in the app. Physical-device signing and distribution are separate from Simulator validation.

## Architecture

Agents → authenticated ingestion → Worker → D1 → authenticated feed → iOS / web.

The ingestion API accepts reports; it does not schedule agents or autonomously scrape publishers. GET ingestion must be called deliberately by an agent, never embedded in browser links or images. Prefer POST for long text. Feed pagination uses a timestamp/ID cursor so new arrivals do not shift the older pages. Story content is immutable; the only mutation is a writer-authenticated retraction tombstone (`DELETE /v1/stories/:id`), which hides a story from default listings without editing or deleting it. Duplicate submissions return the stored report.

The implementation follows Cloudflare's [D1 setup](https://developers.cloudflare.com/d1/get-started/) and [migration workflow](https://developers.cloudflare.com/d1/reference/migrations/).
