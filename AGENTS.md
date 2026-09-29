# Agent guide

## No secrets in this repo

Never commit tokens, API keys, Plaid credentials, or signing files. Reader/writer tokens live in Cloudflare secrets and Keychain; Plaid keys are entered in the app (see [PLAID.md](PLAID.md)). `.gitignore` already excludes `.env*`, `.dev.vars`, `.secrets/`, `*.p8`, `*.p12`.

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

**Linux/cloud agents cannot build or run the iOS app.** If you change SwiftUI there, say plainly in your summary that the change is uncompiled and unseen, and rely on the PR's iOS CI job (which also uploads a launch screenshot artifact). Do not claim iOS UI "works" without a screenshot or a passing CI build.

### What to report

In your final message, state which screenshots you looked at and what they showed, or explicitly that you could not produce one and why.
