# Newswire iOS

SwiftUI reader for `../API.md`. iOS 26+, Swift 6 with approachable concurrency and main actor isolation. `project.yml` is authoritative; regenerate with `xcodegen generate`.

The HTTPS server URL defaults to `https://bryce-newswire.bryce-e19.workers.dev`. Configure a reader token in Settings. Tokens are stored in device-only Keychain, never UserDefaults. Only authenticated story GET requests are issued. Redirects are rejected; network responses use an ephemeral session. No writer secret or synthetic market data is included.

Foreground polling runs approximately every 30 seconds and pauses during filter debounce. Polling and pull refresh stage newer stories behind a banner without changing the visible rows. Selecting the banner returns to the newest page; older pages load as the footer appears, with Load Older available for retry. Failed requests retain the currently loaded stories in memory; cached pages restore immediately on launch.

Story bodies containing HTML (`StoryHTML.isHTML`) render through `StoryBodyView` with native SwiftUI text instead of raw tags: paragraphs, headings, ordered/unordered lists, blockquotes, preformatted blocks, rules, links (HTTP/S only), and bold/italic/underline/strikethrough/code runs. Script, style, and head content is dropped, entities are decoded, and unsupported tags are ignored while their text is kept. Plain-text bodies render unchanged.

The feed uses amber metadata, visible ticker symbols, and an optional headlines-only mode. Long-press a story for source and share actions; the reader keeps those actions at the bottom. The app icon is a minimal newspaper on black.

Breaking and urgent stories with images use a wide hero image below the story text. Other stories keep the compact thumbnail. Long-press an illustrated story and choose Use large image or Use thumbnail to save an override for that story. Headlines-only mode keeps images compact, and failed image loads fall back to text.

## Build and test

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Newswire.xcodeproj -scheme Newswire -destination 'generic/platform=iOS Simulator' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Newswire.xcodeproj -scheme Newswire -destination 'platform=iOS Simulator,id=DAA72EBB-037D-4E20-A661-9C9D969194D0' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
```

For Debug Simulator builds only, process environment variables `NEWSWIRE_TEST_URL` and `NEWSWIRE_TEST_READER_TOKEN` optionally configure the connection at launch. The URL must pass HTTPS validation. The token is written to Keychain and remains available on subsequent launches without the environment override. Values are never logged. When launching through simctl, supply the corresponding `SIMCTL_CHILD_` prefixed environment variables from your existing secret environment; do not put secrets in files, schemes, or shell history. Release and physical-device builds ignore these overrides.

Live pipeline, visual acceptance, signing, and physical-device deployment are separate from the no-sign build and contract tests.

## Release

`scripts/release.sh` builds Release, signs with the team wildcard development profile (no push entitlement), installs on the iPhone when it is reachable, and publishes to https://apps.brmkhe.com/newswire. The build number is tracked in `scripts/.build-number`.

Rows show an on-device Apple Intelligence summary for publisher stories when the model is available: the article page is fetched, its paragraphs are extracted, and Foundation Models writes one sentence of at most 25 words, shown in up to three lines and cached in `newswire-summaries-v2.json`. Paywalled or script-rendered pages fall back to the feed summary.
