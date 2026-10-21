# Deterministic monitor

A rules engine that publishes Newswire stories from threshold checks against public data. The only model in the loop is the `headlines` topic classifier. It runs every minute on the Mac mini (`bryces-mini-2`, Linux) under a systemd user timer, so an alert reaches the wire within a minute or two of the underlying number crossing its threshold.

The Mini uses `NEWSWIRE_CLASSIFIER_PROVIDER=opencode-go`: the existing OpenCode Go subscription (`deepseek-v4.1-flash`) at `https://opencode.ai/inference/go/v1/chat/completions`, with no credit-billed fallback. Answers must contain a known choice and a finite confidence in [0, 1] for every question; malformed or unavailable answers fail closed. The credential comes from `NEWSWIRE_GO_API_KEY` or the existing protected OpenCode configuration. The default route tries free DeepSeek then this same subscription, as does Brain. Classifier identity changes invalidate old verdict caches; run reports count the actual responding model. On October 19, free Jev was blocked by a provider network/IP restriction (not an account restriction), paid Jev returned HTTP 402, and direct free DeepSeek also failed. The subscription was verified before switching the Mini.

The opt-in legacy `NEWSWIRE_CLASSIFIER_PROVIDER=jev` headline classifier uses OpenCode Zen's Jev 1.13 at `https://opencode.ai/zen/v1/systemone`. Each request tries the free `jev-1.13-free` first and falls back to paid `jev-1.13` (billed to Zen credits) when the free model is rate-limited, cooling down, erroring or unreachable. A malformed answer from either model fails closed without retrying. Its key is read from `NEWSWIRE_ZEN_API_KEY` or the mode-600 `~/.config/newswire/zen-key` file. Requests are serialized and spaced at least one second apart. HTTP 429 stores that model's Retry-After deadline in `~/.config/newswire/zen-cooldown.json`, and later monitor processes skip that model until the deadline. Each run report lists `classifier_calls` per model, so paid usage is visible. If both models fail, classification reports both errors. A running timer alone does not prove stories are arriving: check `headlines classifier` failures and the latest publisher-story `received_at`. The production smoke check now also queries publisher headlines separately and fails if no valid receipt is present or the newest receipt is over six hours old, even on HTTP 200. Six hours is a conservative operational alert threshold, not a promise of continuous news volume; it applies on weekends too. It uses actual receipt time, not original publication time, so a backfill is not misrepresented as having arrived earlier.

RSS/X intake is archived before classification in mode-600 `~/.config/newswire/raw-headlines.json`, with immutable first-seen timestamps, a seven-day retention window, and a 10,000-record cap. This raw archive contains unclassified material, not approved wire stories. It continues collecting during classifier outages and is included in explicit backfill runs. A quota cooldown can therefore pause publication without losing all incoming raw headlines. On October 12 the recovery published 21 stories before Zen returned FreeUsageLimitError with a reset of October 13 at 8 p.m. Eastern. This is a free-tier capacity limit, not an intentional weekend schedule.

For outage recovery, `node scripts/monitor/run.mjs --only=headlines --backfill-hours=96 --limit=200` widens feed eligibility for one run and suppresses notifications automatically. Pause the timer and wait for an active run to finish before running recovery, then restore the timer. Rolling RSS feeds do not guarantee a complete historical archive. Publication dates remain original, while the server assigns the actual recovery receipt time. Recovery cannot retroactively improve a point-in-time backtest.

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

`headlines` also dedupes across outlets, since the same event arrives from several publishers with different article IDs (`scripts/monitor/headline-dedupe.mjs`). Each run pages through every story published in the last `dedupe_hours` (default 24). Before classification, a headline is dropped without asking Jev when its canonical link (tracking parameters, `www` and fragments removed) is already on the wire, when its title and summary repeat one exactly, or when its title is near-identical (at least 80% of significant words shared) with the same figures in title and summary, so a revised data release under a reused title still reaches Jev. Quote, option-chain and calendar pages are prefiltered. An on-topic candidate that shares two significant title words with earlier stories is compared in one Jev call against the five closest, including stories accepted earlier in the same run; Jev picks either the matching story or `new`. Syndication, rewording and reactions count as repeats; changed figures or guidance, a new reporting period, a denial, escalation, restored supply, or talks becoming a signed or failed deal count as new. An answer below `min_confidence` is treated as a repeat. If the published history or Jev is unavailable, possible copies are deferred to the next run and reported in failures; exact copies are still dropped. Every decision (new, duplicate with the story it repeats, or deferred) is kept for seven days in `~/.config/newswire/headline-dedup.json`.

Before Jev, a structural pre-filter drops formats it always rejects: publisher URLs with a path segment in `skip_sections` (default `video`, `videos`, `live`, `live-updates`, `live-news`, `opinion`, `opinions`, `briefing`, `podcast`, `podcasts`, `newsletters`, `gallery`, `pictures`, `interactive`), and X posts whose letters are mostly outside the Latin alphabet. It uses only the URL and script, never topic keywords; the article version of a filtered video still goes through Jev.

To keep Jev input small, classification sends the title plus at most 300 characters of summary, asks the topic question alone first, and asks format and priority only for stories that are on-topic or already matched a topic search. Exact and near-identical copies skip classification entirely.

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
| `macro` | CPI and core CPI, the jobs report (payrolls, unemployment, wages), jobless claims, core PCE, PPI, GDP, retail sales and JOLTS. CPI, payrolls, PCE and GDP always notify; the others notify on large moves | FRED |
| `global` | KOSPI, Nikkei, Hang Seng, Shanghai, Taiwan, ASX, Nifty, DAX, FTSE, CAC and Euro Stoxx moves of 1.5% (notify at 2.5%), and dollar-yen, dollar-won, euro, sterling and yuan moves of 1% (0.5% for yuan) | Yahoo Finance |
| `fiscal` | Trillion-dollar debt milestones, monthly debt growth above $300B, fiscal-year interest cost, debt to GDP, IMF world debt rankings | US Treasury, FRED, IMF |
| `fed` | Target range changes, and four-week balance sheet moves above $100B | FRED |
| `treasury` | Coupon auction announcements and settled results within 36 hours | Treasury Fiscal Data |
| `household` | 30-year mortgage rate moves of 10bp, whole-percent crossings, gasoline moves of 3%, yearly extremes | FRED |
| `congress` | Periodic transaction reports filed by watched members of Congress within ten days | US House Clerk |
| `disasters` | Magnitude 6+ earthquakes | USGS |
| `policy` | Executive orders and significant final rules | Federal Register |
| `infrastructure` | Major provider outages, new CISA exploited vulnerabilities, FAA ground stops | Status pages, CISA, FAA |
| `trending` | Hacker News items above 600 points | Hacker News |
| `contracts` | Pentagon contract actions of $250M or more in the past ten days, tagged with the contractor's ticker when known | USAspending.gov |
| `shipping` | Seven-day ship transits through Hormuz, Suez, Bab el-Mandeb, Panama, Malacca, Bosporus, Taiwan Strait or the Cape down 30% or up 40% against the prior 30 days | IMF PortWatch |
| `headlines` | Publisher stories that Jev classifies onto a watchlist topic, once per story | Publisher RSS feeds (news, business, tech, AI labs), Google News, X Following timeline |

Weather coverage was removed deliberately: hurricane tracking and extreme NWS alerts fired far more often than their news value justified, so `disasters` now covers earthquakes only. `earnings` claims item 2.02 filings and `equities` skips them, so no filing publishes twice.

Attention signals from `trending` are labeled as such in the story text, because a pageview count establishes interest rather than fact. IMF debt figures are labeled projections, and the debt-to-GDP ratio notes that its two inputs cover different quarters.

## Insider and congressional filings

The `insiders` rule reads each Form 4 XML document, sums non-derivative transactions by SEC transaction code, and prices them from the filing itself. Only open-market purchases (code P) and sales (code S) above $2 million publish. Grants, option exercises, tax withholding, and gifts are parsed but never published, since they are compensation mechanics rather than a decision to buy or sell. Purchases and anything above $50 million are marked `urgent`. Every story notes that the filing may cover a preplanned 10b5-1 sale, because the form does not always make that distinguishable.

The `congress` rule reads the House Clerk\u2019s annual disclosure archive, a ZIP that is unpacked in memory, and reports periodic transaction reports from a watch list that includes Nancy Pelosi, Ro Khanna, Josh Gottheimer, Marjorie Taylor Greene, Dan Crenshaw, and congressional leadership. A periodic transaction report covers the member, a spouse, or a dependent child. The story links to the filing rather than asserting what was traded, because the assets and value ranges live in a scanned PDF that no deterministic check should be asked to interpret. Members are matched by surname, so adding a name with a common surname risks collisions.

Senate filings are not covered. The Senate electronic system requires an interactive session that a scheduled job should not be faking.

## Headlines watchlist

The `headlines` rule watches publisher RSS feeds and, for topics defined with a `query`, Google News search results, then publishes stories that fall squarely under a topic in `scripts/monitor/rules/headlines.watchlist.json`. It preserves the publisher's headline, resolves Google News links, removes Yahoo's `.tsrc` syndication parameter, labels each story with its matched topic, and fires once per feed GUID. Only stories published within `window_minutes` (default 30, overridable per feed) are considered; Yahoo and MarketWatch use 120 minutes to tolerate discovery delays. Run `--seed` after editing the watchlist to record current matches without publishing them.

Yahoo coverage uses its working ticker RSS endpoint plus Google News discovery across finance.yahoo.com; the old `/rss/topstories` and `/news/rssindex` endpoints return 404. MarketWatch uses `mw_topstories`; `mw_marketpulse` stopped updating. Finance coverage includes company guidance, analyst actions, credit and banking, and evidence-based market analysis. Only the market-analysis topic accepts features, only from publishers, at normal priority. Publisher articles are considered before X during deduplication and lead X at equal priority; `max_x_per_run` (default 2) keeps X supplemental. Classification cache entries are invalidated when topic or question definitions change.

Macro coverage adds primary sources that move rates, oil and shipping before outlets rewrite them: Federal Reserve press releases and speeches, BEA releases (GDP, PCE, trade), ECB press, EIA Today in Energy, gCaptain and FreightWaves. They pass the same topic and format classification, so routine bank approvals and trade-press features are filtered out. The October 2026 audit rejected the BLS feed (a single static item), EIA press and what's-new feeds (empty or low-value data notices), OilPrice.com (mostly opinion that would pass as market analysis) and Maritime Executive (feed returns 404). BLS figures already arrive through the FRED-based macro rule.

Posts from the X Following timeline of the logged-in account enter the same pipeline as publisher headlines. `scripts/monitor/x.mjs` runs `bird home --following` at most every `X_POLL_MINUTES` (default 5) using the `AUTH_TOKEN`/`CT0` cookies in `~/.config/bird/x.env` on the mini, caches the result in `~/.config/newswire/x-timeline.json`, and drops replies, reposts, and posts under 60 characters. They get the same window, topic, format, priority, and duplicate checks, so only hard news on a watchlist topic publishes, tagged `x` and linked to the post. Set `"x": false` in the watchlist to turn it off. The cookies come from a browser session; signing out of X there expires them and the rule reports `X Following` in failures.

Bloomberg article pages sit behind a PerimeterX bot wall and a paywall, so the app cannot read them, and Bloomberg's own feeds are not watched; the same news arrives from readable outlets. If a Google News topic search still surfaces a Bloomberg story, then before publishing it `scripts/monitor/syndication.mjs` searches Google News for a copy republished by a Bloomberg wire licensee (Yahoo Finance, Mint, TradingView and others), accepting only pages that carry the wire's `(Bloomberg) --` dateline, and links that copy instead. With no copy, the story is held for up to `syndication_wait_minutes` (default 10), so if another outlet reports the same news in that time it publishes first and the Bloomberg version is dropped as a duplicate; after the wait it publishes with the Bloomberg link.

Classification uses TypeSafe System One (Jev), with one request per new story carrying three choice questions. `format` separates hard news about a specific new event from analysis, opinion, explainers, profiles, essays, and campaign color; only confident `news` verdicts publish. `topic` labels every topic with a `description` plus `off-topic`, and a story publishes only when Jev picks a topic with confidence at or above `min_confidence` (default 0.7). `priority` picks `breaking`, `urgent`, or `normal` and overrides the topic's default priority when confident. `via` and `query` stories skip the topic question but still get a priority. The API key is read from `TYPESAFE_API_KEY`, `~/.config/newswire/typesafe-key`, or `~/Desktop/typesafe-key.md`; `TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL` override the endpoint and model. Verdicts are cached in `~/.config/newswire/headlines-verdicts.json` for twice the window, so each story is classified once. If the key is missing or the API fails, the failure is reported and only `via` and `query` topics publish.

A topic needs an `id`, a `label`, a `category`, and one of three matchers: a `description` for the classifier, a `query` string for a Google News search (prefer site-scoped queries like `site:anthropic.com/news`; a bare keyword query is a firehose), or neither — a topic with no `description` and no `query` matches only stories whose feed carries its `id` in a `via` array, which is how the AI lab pages publish every announcement. The story's `priority` and `category` come from the highest-priority topic matched. The `feeds` array is the surveyed publisher list; descriptions are the throttle on volume, so keep them narrow and concrete. Classification establishes that a publisher covered a topic, not that the claim is true, and each story says so.

## Push notifications

After publishing, `run.mjs` sends an APNs alert for every new `breaking` story to each device registered with the Worker (`POST /v1/devices` from the iOS app, listed with the writer token). Tapping the alert opens the source link. When a run publishes only normal stories, it instead sends a silent background push (`apns-push-type: background`) so the app refreshes its feed, images and article text while suspended; these are coalesced to one per 20 minutes (`APNS_WAKE_MINUTES`) across the monitor and Brain scraper, tracked in `~/.config/newswire/apns-wake.json`, and any alert push resets the interval. Devices that APNs reports as unregistered are removed. Sending needs an APNs auth key at `~/.config/newswire/apns-key.p8` and `{"key_id": "..."}` in `~/.config/newswire/apns.json` (team `A792L5W262` by default); `APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_TOPIC` override them.

## Priority

`breaking` covers 3% index moves, VIX above 30, 20% drawdowns, magnitude 7+ quakes, debt milestones, and Fed target changes. `urgent` covers 2% index moves, 52-week extremes, 20bp yield moves, earnings 8-Ks, and executive orders. Everything else is `normal`.

## Forecasts and notification topics

`macro` copies ForexFactory's week of scheduled releases (forecast and previous) into the Worker at most hourly (`scripts/monitor/calendar.mjs`), then reads the Worker's `releases` tool so each US release story states the consensus and is raised to breaking when the miss is large (CPI 0.2 points, payrolls 75,000, unemployment 0.2 points, retail sales 0.5 points). A story's notification topic comes from its tags (`topics` in `apns.mjs`); devices that muted a topic in the app's Notifications settings are skipped.

## Ship positions

`scripts/ships/stream.mjs` runs on the mini as `newswire-ships.service`, holds an AISStream websocket for eight chokepoint boxes and posts positions to the Worker every three minutes. It needs a free key from https://aisstream.io saved to `~/.config/newswire/aisstream.key`; without one it exits after logging that. Deploy with `rsync -a scripts/ships/ mini:newswire/scripts/ships/` and `systemctl --user restart newswire-ships`.

## Adding a rule

A rule module exports `id` and an async `run()` returning `{ events, failures }`. Each event needs `key`, `title`, `summary`, `source`, `url`, `category`, and `priority`, plus optional `published_at`, `tickers`, and `tags`. Register it in `run.mjs`, and add it to the `cooldown` map only if it should be allowed to repeat. A rule that throws is isolated: its failure is reported and every other rule still publishes.

The normal monitor run also calls `syncCalendar` hourly. It preserves Nasdaq economic history in D1, refreshes a rolling seven days (or catches up after downtime), posts FRED snapshots for edge-access failures, and collects public economic RSS coverage. Initial history backfill is 60 days; `syncCalendar({force:true, backfill:60})` can repair missed days without publishing stories or sending notifications. Failures are included in the monitor report, and retries are throttled to the next hour. Dry runs, seed runs, and `--only` runs skip this sync.
