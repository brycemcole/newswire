# Market Pulse

An experimental, news-only macro outlook with an arrival-time replay. Version 1 uses conservative rules over the immutable titles already stored by Newswire. It does not use prices to calculate the outlook, interpret every story, predict a percentage return, or give a calibrated probability.

Version 1.1 restricts energy contributions to explicitly named major supply-risk regions or global oil supply. Inspection of the first unscreened forward snapshot found an unrelated Cuba energy headline dominating the generic energy rule; the original snapshot is retained, and subsequent runs use v1.1. This adjustment occurred before the target session, but it is a model revision, not an independent validation. Earlier October 12 replay figures below retain v1.

Version 1.2 adds bounded corroboration. Within an event group, each additional independent publisher raises an unconfirmed report ("reportedly", "claims") by 0.1 confidence, capped at the confirmed level of 0.8. Regional editions of one outlet count once and X posts do not corroborate. Repeated confirmed coverage still adds nothing, so 30 syndicated copies score the same as one. Each evidence item reports `independent_sources`.

Version 2.1 replaces the keyword rules with a Jev read of every headline when reads are available, and returns plain-language text. `scripts/monitor/impacts.mjs` runs after each monitor pass on the Mini. It reads headlines from every feed in the raw archive (not only stories published to the wire), skips quote pages, culture feeds and near-identical copies, and asks Jev in one call whether each headline is likely to push the S&P 500 lower, higher or not at all at the next session, through which channel (energy, rates, trade, growth, credit, geopolitics, earnings) and how strongly. Reads below 0.5 confidence count as no effect. Moving headlines are stored in the `pulse_impacts` table with their first-seen time, so replays only use headlines that had arrived by the cutoff. Each headline counts by size, confidence and age (12-hour half-life); within a channel, `tanh` saturates repeats, so many outlets covering one event cannot outweigh it. Channel exposure flips energy for XLE. News is capped at ±25 points. The response adds `call` (for example "Expect a lower open"), a one-sentence `summary`, ranked `drivers` with the data behind each, and `coming_up` releases. Each monitor pass reads at most 25 headlines, roughly 400 to 600 Jev calls a day at current feed volume.

Version 2.0 adds two deterministic components to the news score, served by `GET /v1/market-pulse?symbol=SPY&history=12` and shown on the iOS home feed.

Market inputs (`backend/src/market-inputs.ts`) score 11 instruments from delayed Yahoo 5-minute bars: S&P 500 futures, WTI crude, VIX, USD/JPY, the 10-year yield, HYG, the dollar index, Euro Stoxx 50, Nikkei 225, copper and bitcoin. Each move is 70% of its 24-hour change and 30% of its 1-hour change, passed through `tanh` against a typical move size, so a sudden spike registers before the daily change catches up and one runaway input cannot dominate. Each input has a direction and per-profile exposure (crude hurts SPY and DAL, helps XLE). The total is capped at ±35 points and needs three live inputs. US instruments go stale after 3 hours; Europe and Asia stay current for 18 hours, so their close counts into the next US morning. Replays use only bars that had closed by the cutoff; the in-progress quote is used only for the live snapshot.

Economic data scores US high-impact releases from the existing calendar in the last 24 hours by surprise against forecast, scaled by each series' surprise threshold. Hotter inflation, wages or joblessness is a headwind; stronger activity is a smaller tailwind. A high-impact release still due within 18 hours keeps confidence low. The response reports `horizon`: `next open` outside the regular session, `rest of session` during it.

Bellwether earnings cover 21 companies that move an index or profile on their own: the megacaps, TSMC and ASML, the large banks, Netflix, Walmart, Lilly, UnitedHealth, Exxon, Chevron, Delta and United. A 15-minute cron trigger stores each company's next report date, consensus EPS and the matching reported quarter from Yahoo in `bellwether_earnings`; a company that fails to load keeps its last good row, and `components.earnings.coverage` reports how many loaded and any error. Pulse requests only read that row because 21 Yahoo calls do not fit in one request's subrequest budget. A scheduled report has no direction, so it never moves the score: it appears in `coming_up` (within 36 hours, with "before the open" or "after the close" because Yahoo's exact times are placeholders) and, for a company weighted 1 or more in the profile, keeps confidence low within 18 hours. For 24 hours after a report, each company adds `tanh((surprise − 4%) / 8%) × 1.5 × weight`, capped at ±6 points in total. The 4% offset is there because about three in four companies beat, so a small beat is the expected result. Guidance and revenue reach the score only through the Jev `earnings` headline channel. Requests for a past time omit earnings because Yahoo does not keep past estimates.

Medium-impact US releases (Fed speakers, auctions, claims, regional surveys) are listed in `coming_up` but are not scored and do not lower confidence. Releases at the same minute are grouped into one entry, so CPI m/m, y/y and core show once as "CPI".

Backtest (`scripts/market-pulse/backtest-market.mjs`, market inputs only, 60 sessions from July 20 to October 12, 2026): the 7 a.m. Eastern score tracked the gap from the prior close to the open, with correlation 0.45 for SPY, 0.48 for QQQ and 0.46 for DAL, and the right direction on about two thirds of days with a score at least 2 points from neutral (65% SPY, 70% QQQ). It also does this without futures, so it is more than a restatement of the futures move. For XLE it was near zero. From the open or midday to the close, correlation was between −0.2 and 0.12, which is no usable edge; prices largely absorb overnight catalysts by the open. Yen weakness had a negative correlation with the gap and was removed as a tailwind; a yen rally remains a headwind. This is one short window, overlapping the period used to choose the weights, so it is evidence of fit rather than out-of-sample validation.

## Read the current outlook

Authenticated readers and the writer can request:

```text
GET /v1/market-pulse?symbol=SPY
GET /v1/market-pulse?symbol=QQQ&as_of=2026-10-12T11:00:00Z
GET /v1/data/market/pulse?symbol=SPY
```

The data-tool catalog and MCP surface expose `market_pulse` as well. Supported exposure profiles are SPY, QQQ, XLE, and DAL. DAL is an example airline exposure, not a complete stock model. Other tickers are rejected rather than assigned invented exposures.

Each request calculates from the current stored stories without a result cache or external model call. A newly ingested event appears on the next request, subject to the rules and evidence limits. This is request-driven refresh, not a push subscription or a scheduled notification. No database migration is required. A backend deployment is required to enable these routes in production.

## Interpretation

The baseline is 50. Headwinds subtract points and tailwinds add them. Below 40 is labeled headwinds; above 60 is tailwinds. The five factor budgets total 50 points:

| Factor | Maximum base points | Examples of recognized events |
|---|---:|---|
| Energy | 12 | Explicit attacks/supply disruption; actual supply restoration |
| Trade | 10 | New US/China tariffs or restrictions; tariff reductions |
| Rates/inflation | 10 | Fed rate decisions; explicit inflation surprises |
| Growth | 8 | Explicit US activity beats or weakness |
| Credit | 10 | Explicit systemic US/global funding stress |

For each factor, the strongest positive and strongest negative evidence offset. The contribution is multiplied by that symbol's fixed exposure. Energy supply risk has opposite signs for XLE and DAL; these are hypotheses, not fitted coefficients. Contributions decay with a 36-hour half-life inside a 96-hour window. Publisher evidence receives weight 0.8, qualified reports 0.55, and X-only evidence 0.4. These weights describe a heuristic, not measured source accuracy.

Repeated evidence is grouped by rule and coarse region. Repetitions do not refresh the first publication time or accumulate into a stronger factor. This is deliberately conservative: it may fail to distinguish separate new events in the same region or recognize a material escalation. Titles containing hypotheticals, negation, or questions are left unclassified; summaries are not independently mined for events. Unmatched news is not evidence of neutrality. Company results, valuation, ambiguous policy implications, and comprehensive semantic event extraction are not implemented.

`score` is null when coverage is missing, over 24 hours old, truncated by the 5,000-story API limit, or contains no recognized event. `research_score` retains the underlying calculation for inspection. Generic publisher/X freshness is only a coverage proxy; it does not certify all sources are healthy. Confidence never exceeds medium in this unvalidated model.

## Replay

For a frozen forward outlook, with no future price outcome mixed in:

```sh
node --experimental-strip-types scripts/market-pulse/outlook.mjs --session=2026-10-13
```

Choose the next actual US trading session, excluding exchange holidays. The default cutoff is now; `--as-of=ISO` is optional. Each run gets a new directory, and existing snapshot files are not overwritten. Scores recompute from the currently received archive; recovered stories enter only after their real receipt timestamp.

During a classifier outage, `--raw-archive=/path/to/raw-headlines.json` can additionally include the monitor's raw intake. The report is explicitly provisional, carries the unscreened-input warning, uses each raw record's immutable `first_seen_at`, and does not publish any raw story to the wire. It is not equivalent to a normal Jev-screened outlook.

Use Node 22 or newer:

```sh
node --experimental-strip-types scripts/market-pulse/replay.mjs \
  --as-of=2026-10-12T07:00:00-04:00 \
  --out=.build-market-pulse/2026-10-12-0700
```

The collector uses the existing writer-token mechanism for read-only pagination. It never publishes a story, charges a model API, or sends a notification. The output directory contains raw stories and historical price responses, `report.md`, a structured `report.json`, and `timeline.csv`. Keep raw archives under `.build*` so they remain gitignored. Archives can be replayed offline:

```sh
node --experimental-strip-types scripts/market-pulse/replay.mjs \
  --as-of=2026-10-12T07:00:00-04:00 \
  --stories=.build-market-pulse/2026-10-12-0700/stories.json \
  --prices=.build-market-pulse/2026-10-12-0700/prices.json \
  --out=.build-market-pulse/recheck
```

Both `published_at` and server-assigned `received_at` must precede the cutoff. A later-arriving story with an earlier publication time is excluded. Retractions are evaluated at their historical timestamp. Stories without a valid receipt timestamp cannot enter a strict replay. Report hashes identify the model source and archived story array.

Price evaluation is separate. It uses Yahoo five-minute historical bars including extended hours, never today's metadata quote. Only bars ending by the cutoff qualify as a cutoff observation, with a maximum age of 15 minutes. Missing premarket trades remain unavailable. The report separates the pre-cutoff move, cutoff-to-close, open-to-close, previous-close-to-close, and worst subsequent price. Five-minute closes approximate equity session closes; crude uses the same clock, not its exchange settlement. Downloading history later does not prove the quote provider delivered those prices live at the time. Revised historical data and sparse bars remain limitations.

The timeline includes hourly recalculation and each archived arrival, so it captures both new evidence and decay. Archives declare `coverage_start`; snapshots without a complete 96-hour archive window are marked incomplete and withhold their displayed score. The collector requests an extra 72 hours to cover the earlier timeline. Raw data obtained after the cutoff is used only in later snapshots and outcome evaluation.

## October 12, 2026, 7 a.m. Eastern case study

The locally archived run contained 647 eligible stories in the 96-hour window, including 629 publisher/X headlines. Only five titles matched the intentionally narrow macro rules. Latest headline publication was Friday October 9 at 11:20 a.m. Eastern, 67.66 hours before the cutoff; the Saturday Saudi attack was absent from the archive.

| Profile | Underlying calculation | Displayed outlook |
|---|---:|---|
| SPY | 48.42 | Withheld: stale |
| QQQ | 48.74 | Withheld: stale |
| XLE | 51.58 | Withheld: stale |
| DAL | 47.63 | Withheld: stale |

The residual SPY contribution was -1.58 energy points from older supply-risk reporting. At 7 a.m., crude was already up about 1.25% versus Friday at 4 p.m. Subsequent cutoff-to-4-p.m. changes were SPY -0.09%, QQQ -0.57%, XLE +0.92%, and crude +0.71%. DAL lacked a fresh cutoff bar; its open-to-close change was -1.16%. These observations do not validate predictive accuracy.

A read-only check of the live Mini monitor found its headline classifier returning `jev 402; code: billing_error` while the timer remained active. The score cannot reconstruct a missed story as if Newswire had received it. The ingestion outage requires separate provider/account recovery; this change does not alter billing or switch providers.

This is a selected, retrospective single-session case study using rules written after the outcome. To evaluate predictive value, freeze the model and capture forward snapshots over many sessions, then compare subsequent returns and downside risk against neutral and price-only baselines. Do not tune the model on this day and report that as backtest success.

## Checks

```sh
cd backend
npm run typecheck
node --test test/market-pulse.test.mjs test/api.test.mjs test/data.test.mjs
```

Tests cover arrival-time leakage, historical retractions, duplicates, stale/absent data, opposing evidence, profile exposure, live recalculation, authentication, API validation, and exclusion of incomplete/future price bars.
