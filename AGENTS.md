# Agent guide

## No secrets in this repo

Never commit tokens, API keys, Plaid credentials, or signing files. Reader/writer tokens live in Cloudflare secrets and Keychain; Plaid keys are entered in the app (see [PLAID.md](PLAID.md)). `.gitignore` already excludes `.env*`, `.dev.vars`, `.secrets/`, `*.p8`, `*.p12`.

## Financial-data integrity

- Keep source observation time, fetch time, and computation time distinct. A successful request does not establish data freshness.
- Preserve the distinction between unavailable, stale, partial, estimated, and valid zero/neutral values. Do not substitute one for another silently.
- Aggregate completeness and freshness must reflect all included components. A partial refresh must not imply that retained components were refreshed.
- Cached financial data must retain its provenance and applicable session/horizon. Surface material age or refresh failure where the value is consumed.
- Count an input as usable only when the data required for its calculation is present and temporally valid, not merely because its latest price is recent. Prefer the newest valid observation, not a source whose priority ignores observation time.
- Reuse the existing exchange-session calendar for session boundaries, holidays, and early closes rather than implementing another calendar.

For changes to quote, portfolio, or forecast data behavior, state the relevant invariants and acceptance criteria before editing. Test applicable degraded states: partial provider failure, successful responses containing old data, missing comparison baselines, cached forecasts crossing their target horizon, holidays/early closes, conflicting source timestamps, and recovery. Assert status and timestamps as well as values, and verify the user-visible interpretation. Reuse or extend regression tests and fixtures; report which cases were checked and which remain unverified. Keep checks proportional to the change; unrelated formatting changes do not require a full financial-data audit.

## Look at UI changes before you call them done

Type checks and unit tests do not tell you whether a screen looks right. For any change to what a user sees, produce a screenshot, look at it (open the PNG), and fix what is wrong. Screenshots go in `screenshots/` (gitignored). Do not commit them; attach or describe them in the PR instead.

### Web reader (`web/`), works anywhere including Linux/cloud sessions

```sh
NODE_PATH=$(npm root -g) node scripts/screenshot-web.mjs            # writes screenshots/web/desktop.png and phone.png
```

This starts `scripts/preview-web.mjs` (synthetic `[TEST]` stories, token `preview-only`, no network or real data) and captures desktop and phone widths with Playwright. Playwright and Chromium are preinstalled in Claude Code on the web (`PLAYWRIGHT_BROWSERS_PATH` is set; do not run `playwright install`). To capture a different state, copy the script and add clicks before `page.screenshot`.

### iOS app (`ios/`), needs macOS with Xcode

```sh
ios/scripts/screenshot.sh                       # writes screenshots/ios/launch.png
ios/scripts/screenshot.sh ../screenshots/ios/x.png <launch args>
```

It runs xcodegen, builds for the Simulator, launches the app, and grabs `xcrun simctl io ... screenshot`. Extra arguments are passed to the app as launch arguments. The script only captures the launch screen; to reach a deeper screen (for example Settings > Brokerage Sync), drive the Simulator yourself and run `xcrun simctl io booted screenshot screenshots/ios/name.png`, or add a small `#if DEBUG` launch argument that opens the screen you changed.

**Linux/cloud agents cannot build or run the iOS app.** If you change SwiftUI there, say plainly in your summary that the change is uncompiled and unseen, and rely on the PR's iOS CI job, which only checks that the app compiles. Do not claim iOS UI "works" without a screenshot.

### What to report

In your final message, state which screenshots you looked at and what they showed, or explicitly that you could not produce one and why.

## Production

The Worker is on Cloudflare's free plan: 10 ms of CPU per request. Everything except `/v1/stories`, `/v1/devices`, `/v1/ingest`, `/v1/attest` and `/v1/brain/` is forwarded to the `Compute` Durable Object, which allows 30 s. A new heavy route needs no change; a new route added to the light list must stay well under 10 ms.

Unit tests cannot see production limits. After every deploy run `node scripts/smoke/check.mjs --no-alert` on the Mini; it makes the app's real requests and exits non-zero on any failure. `newswire-smoke.timer` runs it every five minutes and pushes to registered devices when the set of failing requests changes.
