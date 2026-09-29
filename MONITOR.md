# Deterministic monitor

A rules engine that publishes Newswire stories from threshold checks against public data. The only model in the loop is the `headlines` topic classifier. It runs every minute on the Mac mini (`bryces-mini-2`, Linux) under a systemd user timer, so an alert reaches the wire within a minute or two of the underlying number crossing its threshold.

Every story states its source, its measured values, and the timestamp of the reading. Rules report what moved and never assert why.

## Running

```sh
node scripts/monitor/run.mjs --dry-run          # evaluate everything, publish nothing
node scripts/monitor/run.mjs --only=fiscal      # one or more rules, comma separated
node scripts/monitor/run.mjs --seed             # record current events without publishing
node scripts/monitor/run.mjs                    # evaluate and publish
node scripts/monitor/install-agent.mjs          # load a macOS launchd agent instead (default 60s)
```

Run `--seed` once after adding a rule that reports dated observations, otherwise its first live run publishes a backlog of figures that are already old news. On the mini the code lives in `~/newswire/scripts/monitor`, deployed with `rsync -a --delete scripts/monitor/ mini:newswire/scripts/monitor/`, and runs from `~/.config/systemd/user/newswire-monitor.{service,timer}`. Logs are in `journalctl --user -u newswire-monitor`. The laptop launchd agent is unloaded so the two never run at once.

The writer token is read from `~/.config/newswire/writer-token` or `NEWSWIRE_WRITER_TOKEN`, and is never printed. Fired events are recorded in `~/.config/newswire/monitor-state.json`, whose keys expire after 21 days.

## Deduplication

`external_id` is a SHA-256 digest of the rule\u2019s event key, so a repeated event maps onto the story already stored and the Worker returns `duplicate: true`. Keys embed the session date and a magnitude bucket, so a 1% drop that deepens to 2% publishes a second, more urgent story while further drift inside the same bucket stays quiet.

Continuous rules (`markets`, `volatility`, `rates`, `equities`, `crypto`, `sectors`) may repeat after a cooldown of 6 to 12 hours. Every other rule covers a specific filing, quake, release, or milestone and fires exactly once.

`headlines` also dedupes across outlets, since the same event arrives from several publishers with different article IDs. Each run reads the stories published in the last `dedupe_hours` (default 24) from the Worker. A headline whose title words overlap a published title by `near_identical` (Jaccard, default 0.6), or that repeats a title seen earlier in the run, is dropped without asking Jev. A headline that shares at least two significant words with up to five published titles is sent to Jev with only those titles, and publishes only when Jev answers `new` with at least `min_confidence`. Follow-ups, reactions, and reviews of the same story count as repeats; a decision that changes the outcome, such as talks becoming a signed deal, counts as new. If the published list or Jev is unavailable, the check fails open and reports `headlines dedupe` in failures.

To keep Jev input small, classification sends the title plus at most 300 characters of summary, asks the topic question alone first, and asks format and priority only for stories that are on-topic or already matched a topic search. Near-duplicates skip classification entirely.

## Rules

| Rule | Triggers | Source |
| --- | --- | --- |
| `markets` | Index or futures moves of 1/2/3%, 52-week highs, 10% and 20% drawdowns | Yahoo Finance |
| `sectors` | Sector ETF moves of 2% or more, urgent at 4% | Yahoo Finance |
| `volatility` | VIX above 20/30/40, or a one-session move of 20% | Yahoo Finance |
| `rates` | 10-year yield moves of 10bp or crossings of 4%/5%, crude 4%, gold 3%, dollar index 1%, high-yield spreads above 5 points, curve inversion | Yahoo Finance, FRED |
| `equities` | Megacap moves of 5% or more, and non-earnings 8-K filings within two days | Yahoo Finance, SEC EDGAR |
| `earnings` | Item 2.02 earnings 8-Ks from fourteen watched companies within two days | SEC EDGAR |
| `insiders` | Form 4 open-market buys or sells above $2M by officers, directors, and ten percent owners at ten large companies | SEC EDGAR |
| `crypto` | Bitcoin 5% or Ether 7% daily moves, round-number crossings, 52-week highs | Yahoo Finance |
| `macro` | CPI, unemployment, payrolls, and jobless claims, with changes computed rather than restated | FRED |
| `fiscal` | Trillion-dollar debt milestones, monthly debt growth above $300B, fiscal-year interest cost, debt to GDP, IMF world debt rankings | US Treasury, FRED, IMF |
| `fed` | Target range changes, and four-week balance sheet moves above $100B | FRED |
| `treasury` | Coupon auction announcements and settled results within 36 hours | Treasury Fiscal Data |
| `household` | 30-year mortgage rate moves of 10bp, whole-percent crossings, gasoline moves of 3%, yearly extremes | FRED |
| `congress` | Periodic transaction reports filed by watched members of Congress within ten days | US House Clerk |
| `disasters` | Magnitude 6+ earthquakes | USGS |
| `policy` | Executive orders and significant final rules | Federal Register |
| `infrastructure` | Major provider outages, new CISA exploited vulnerabilities, FAA ground stops | Status pages, CISA, FAA |
| `trending` | Hacker News items above 600 points | Hacker News |
| `headlines` | Publisher stories that Jev classifies onto a watchlist topic, once per story | Publisher RSS feeds (news, business, tech, AI labs), Google News |

Weather coverage was removed deliberately: hurricane tracking and extreme NWS alerts fired far more often than their news value justified, so `disasters` now covers earthquakes only. `earnings` claims item 2.02 filings and `equities` skips them, so no filing publishes twice.

Attention signals from `trending` are labeled as such in the story text, because a pageview count establishes interest rather than fact. IMF debt figures are labeled projections, and the debt-to-GDP ratio notes that its two inputs cover different quarters.

## Insider and congressional filings

The `insiders` rule reads each Form 4 XML document, sums non-derivative transactions by SEC transaction code, and prices them from the filing itself. Only open-market purchases (code P) and sales (code S) above $2 million publish. Grants, option exercises, tax withholding, and gifts are parsed but never published, since they are compensation mechanics rather than a decision to buy or sell. Purchases and anything above $50 million are marked `urgent`. Every story notes that the filing may cover a preplanned 10b5-1 sale, because the form does not always make that distinguishable.

The `congress` rule reads the House Clerk\u2019s annual disclosure archive, a ZIP that is unpacked in memory, and reports periodic transaction reports from a watch list that includes Nancy Pelosi, Ro Khanna, Josh Gottheimer, Marjorie Taylor Greene, Dan Crenshaw, and congressional leadership. A periodic transaction report covers the member, a spouse, or a dependent child. The story links to the filing rather than asserting what was traded, because the assets and value ranges live in a scanned PDF that no deterministic check should be asked to interpret. Members are matched by surname, so adding a name with a common surname risks collisions.

Senate filings are not covered. The Senate electronic system requires an interactive session that a scheduled job should not be faking.

## Headlines watchlist

The `headlines` rule watches publisher RSS feeds and, for topics defined with a `query`, Google News search results, then publishes stories that fall squarely under a topic in `scripts/monitor/rules/headlines.watchlist.json`. It publishes the publisher's own headline and link unchanged, labeled with the topic it matched, and fires exactly once per story keyed on the feed GUID. Only stories published within `window_minutes` (default 30) are considered, so a first run never dumps a backlog and a feed that surfaces a story late cannot land it on the wire as old news; run `--seed` after editing the watchlist to record current matches without publishing them.

Classification uses TypeSafe System One (Jev), with one request per new story carrying three choice questions. `format` separates hard news about a specific new event from analysis, opinion, explainers, profiles, essays, and campaign color; only confident `news` verdicts publish. `topic` labels every topic with a `description` plus `off-topic`, and a story publishes only when Jev picks a topic with confidence at or above `min_confidence` (default 0.7). `priority` picks `breaking`, `urgent`, or `normal` and overrides the topic's default priority when confident. `via` and `query` stories skip the topic question but still get a priority. The API key is read from `TYPESAFE_API_KEY`, `~/.config/newswire/typesafe-key`, or `~/Desktop/typesafe-key.md`; `TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL` override the endpoint and model. Verdicts are cached in `~/.config/newswire/headlines-verdicts.json` for twice the window, so each story is classified once. If the key is missing or the API fails, the failure is reported and only `via` and `query` topics publish.

A topic needs an `id`, a `label`, a `category`, and one of three matchers: a `description` for the classifier, a `query` string for a Google News search (prefer site-scoped queries like `site:anthropic.com/news`; a bare keyword query is a firehose), or neither — a topic with no `description` and no `query` matches only stories whose feed carries its `id` in a `via` array, which is how the AI lab pages publish every announcement. The story's `priority` and `category` come from the highest-priority topic matched. The `feeds` array is the surveyed publisher list; descriptions are the throttle on volume, so keep them narrow and concrete. Classification establishes that a publisher covered a topic, not that the claim is true, and each story says so.

## Push notifications

After publishing, `run.mjs` sends an APNs alert for every new `breaking` story to each device registered with the Worker (`POST /v1/devices` from the iOS app, listed with the writer token). Tapping the alert opens the source link. When a run publishes only normal stories, it instead sends a silent background push (`apns-push-type: background`) so the app refreshes its feed, images and article text while suspended; these are coalesced to one per 20 minutes (`APNS_WAKE_MINUTES`) across the monitor and Brain scraper, tracked in `~/.config/newswire/apns-wake.json`, and any alert push resets the interval. Devices that APNs reports as unregistered are removed. Sending needs an APNs auth key at `~/.config/newswire/apns-key.p8` and `{"key_id": "..."}` in `~/.config/newswire/apns.json` (team `A792L5W262` by default); `APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_TOPIC` override them.

## Priority

`breaking` covers 3% index moves, VIX above 30, 20% drawdowns, magnitude 7+ quakes, debt milestones, and Fed target changes. `urgent` covers 2% index moves, 52-week extremes, 20bp yield moves, earnings 8-Ks, and executive orders. Everything else is `normal`.

## Adding a rule

A rule module exports `id` and an async `run()` returning `{ events, failures }`. Each event needs `key`, `title`, `summary`, `source`, `url`, `category`, and `priority`, plus optional `published_at`, `tickers`, and `tags`. Register it in `run.mjs`, and add it to the `cooldown` map only if it should be allowed to repeat. A rule that throws is isolated: its failure is reported and every other rule still publishes.
