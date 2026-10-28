# Newswire iOS

SwiftUI reader for `../API.md`. iOS 26+, Swift 6 with approachable concurrency and main actor isolation. `project.yml` is authoritative; regenerate with `xcodegen generate`.

The HTTPS server URL defaults to `https://bryce-newswire.bryce-e19.workers.dev`. There is no token to enter: the app creates an App Attest key in the Secure Enclave, the server verifies Apple's attestation, and the app holds the resulting 7-day session token in device-only Keychain (renewed silently with a signed assertion), never UserDefaults. App Attest needs a physical device. Only authenticated story GET requests are issued. Redirects are rejected; network responses use an ephemeral session. No writer secret or synthetic market data is included.

Foreground polling runs approximately every 30 seconds and pauses during filter debounce. Polling and pull refresh stage newer stories behind a banner without changing the visible rows. Selecting the banner returns to the newest page; older pages load as the footer appears, with Load Older available for retry. Failed requests retain the currently loaded stories in memory; cached pages restore immediately on launch.

Story bodies containing HTML (`StoryHTML.isHTML`) render through `StoryBodyView` with native SwiftUI text instead of raw tags: paragraphs, headings, ordered/unordered lists, blockquotes, preformatted blocks, rules, links (HTTP/S only), and bold/italic/underline/strikethrough/code runs. Script, style, and head content is dropped, entities are decoded, and unsupported tags are ignored while their text is kept. Plain-text bodies render unchanged.

The feed uses amber metadata, visible ticker symbols, and an optional headlines-only mode. Long-press a story for source and share actions; the reader keeps those actions at the bottom. The app icon is a minimal newspaper on black.

Breaking and urgent stories with images use a wide hero image below the story text. Other stories keep the compact thumbnail. Long-press an illustrated story and choose Use large image or Use thumbnail to save an override for that story. Headlines-only mode keeps images compact, and failed image loads fall back to text.

## SoFi on this device

Portfolio → SoFi on this device opens a dedicated persistent WebKit profile. Sign in and complete verification yourself, navigate to Invest holdings, then choose **Read holdings** and **Use this page**. The app retries the saved portfolio path on activation and every five minutes while active; it leaves the visible browser alone. Cookies stay in WebKit and are not copied to Keychain, logs, model prompts, or the backend. Disconnect clears this profile and its trailing alerts without removing Plaid.

The initial web adapter reads visible semantic tables with explicit Symbol and Shares/Quantity/Contracts columns. It reports partial coverage and unknown quote time; unsupported layouts remain unavailable, and an unreadable page never implies an empty portfolio. Real SoFi sign-in, MFA, holdings layout, and session reuse across app termination still require account verification. Existing SoFi holdings from Plaid are labeled separately with their original sync time.

Trailing alerts evaluate direct Yahoo USD quotes on the device every 15 seconds in the foreground during regular US market hours. They persist the highest price observed since arming, ignore old/future/duplicate observations, and trigger one review notification per arming. Exact option contract symbols are required; the underlying price is never substituted. These alerts do not submit orders, reconstruct missed highs, guarantee a fill price, or run continuously while iOS suspends the app. Pause retains the high; **Start a new high** resets it. No brokerage session or holdings are shared with a model.

Debug launch arguments: `-sofi` opens the real connection screen; `-sofiPreview` shows labeled example alerts without connecting or saving alerts. Focused checks: `NewswireTests/SoFiTests` and `SessionUITests/SoFiUITests`.

## Build and test

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Newswire.xcodeproj -scheme Newswire -destination 'generic/platform=iOS Simulator' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Newswire.xcodeproj -scheme Newswire -destination 'platform=iOS Simulator,id=DAA72EBB-037D-4E20-A661-9C9D969194D0' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
```

For Debug Simulator builds only, process environment variables `NEWSWIRE_TEST_URL` and `NEWSWIRE_TEST_TOKEN` (any accepted bearer token, since the Simulator cannot attest) optionally configure the connection at launch. The URL must pass HTTPS validation. Neither is persisted; supply them on every launch. Values are never logged. When launching through simctl, supply the corresponding `SIMCTL_CHILD_` prefixed environment variables from your existing secret environment; do not put secrets in files, schemes, or shell history. Release and physical-device builds ignore these overrides.

Live pipeline, visual acceptance, signing, and physical-device deployment are separate from the no-sign build and contract tests.

## Release

`scripts/release.sh` builds Release, signs with the team wildcard development profile (no push entitlement), installs on the iPhone when it is reachable, and publishes to https://apps.brmkhe.com/newswire. The build number is tracked in `scripts/.build-number`.

Rows show an on-device Apple Intelligence summary for publisher stories when the model is available: the article page is fetched, its paragraphs are extracted, and Foundation Models writes one sentence of at most 25 words, shown in up to three lines and cached in `newswire-summaries-v2.json`. Paywalled or script-rendered pages fall back to the feed summary.

## Separate device Beta build

Run `xcodegen generate --spec project-beta.yml` before a development install to use **Newswire Beta** (`com.brycecole.newswire.beta`). Its widget, app group, Keychain access, and URL scheme (`newswire-beta`) are separate from the TestFlight app. Run `xcodegen generate` for the original release identity. The `ChartCatalysts` scheme validates the stock chart hold interaction using live AAPL data.

## Ask: options and strategy widgets

Ask can look up options on any ticker (`stock_data` takes a `symbol`, so market-wide chats work too) and render the results as native cards instead of prose. The model writes a fenced block with JSON that names contracts by OCC symbol; the app draws it from the quotes the tool actually returned (`ChatOption`, stored on the message), so prices never come from model text.

- ` ```options ` `{"title":"QQQ Oct 30","contracts":["QQQ261030C00600000"]}` lists contracts with mid, bid–ask, cost per contract, breakeven and IV.
- ` ```strategy ` `{"name":"Bull call spread","outlook":"bullish","legs":[{"contract":"...","side":"buy","qty":1}]}` (also ` ```position `) shows the legs, net cost, max profit and loss, breakevens and an expiry payoff chart, computed by `StrategyAnalysis` from bid/ask. A leg `{"shares":100,"side":"buy"}` adds the stock. Strategies must use one underlying and one expiry; otherwise, or if any leg was never quoted, the card says it can't price it.

Brokerage holdings are never sent to the model, so "positions" here are proposed ones. `-askMarkets -askOptionsSample` opens Ask with sample widgets in Debug builds. The Ask sheet opens from the message button beside the search field in the market dock; text typed there is sent as the first question.

The Ask sheet opens from the message button beside the search field. In a market-wide chat the four starter questions are written by Apple Intelligence from today's index, rate and commodity moves plus the newest feed headlines (`AskSuggestions`). They are cached for 20 minutes, a fixed set shows until they arrive or when the on-device model is unavailable, and `-askStaticSuggestions` pins the fixed set in Debug builds. Return in the composer sends the question; pasting several lines does not send.

## Price alerts and Live Activities

In Settings > Price watching > Live prices and targets, choose a target price, a daily percentage move, or Live Activity only. Targets notify once; percentage alerts compare with the previous close and rearm on a fresh crossing, with a 30-minute cooldown. Delivery setup shows iOS authorization, Apple registration, server sync and the frequent Live Activity setting. A symbol without a target or percentage has no price notification.

While the app is active, each symbol with an active Live Activity is fetched directly from Yahoo every 15 seconds. Polling stops when the app leaves the foreground. In the background, the Mini's `newswire-stock-alerts.timer` checks about every 15 seconds and sends ActivityKit pushes for new observations. iOS controls delivery and may throttle updates. Both paths retain the source observation time, choose newer regular/extended observations, normalize minor currency units, and skip stale or future-dated updates. Failed requests leave the existing quote and stale deadline intact. No quote request is made when no Live Activity is active.
