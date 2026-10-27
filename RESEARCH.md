# Market research

Newswire saves experimental SPY and QQQ forecasts and evaluates them after their target period. The initial score is an index. It is not a probability, a promised return, or evidence of a trading edge.

## Forecast ledger

The writer calls `POST /v1/research/capture` with `{"symbol":"SPY"}`. The server captures its own current pulse, classified news, calendar observations, market inputs, target-price evidence and hashes. Clients cannot backdate a forecast or supply its evidence.

Capture windows use New York time and the exchange session calendar:

| Window | Target |
| --- | --- |
| 08:35–08:50 | Fresh captured pre-market ETF price to the opening bar’s open |
| 09:25–09:30 | Open-to-close return |
| Last 15 minutes of the session | Remaining move from the observed price to the next session open |

One forecast is retained per symbol, target session and horizon. Repeated requests do not replace it. Outside a window the request returns a skip. Missing or stale required prices cannot become an invented baseline. Unexpected exchange closures still require calendar maintenance.

`POST /v1/research/settle` fetches Yahoo market data on the server and settles mature forecasts once. Completed five-minute bars approximate session endpoints; provider delays and later historical corrections remain limitations. Outcomes and their source timestamps remain separate from forecast evidence.

Authenticated readers use `GET /v1/research?symbol=SPY`. The native Market Pulse detail has a Research link showing recorded forecasts, outcomes, source discovery, open questions and evidence. Performance is separated by horizon. Neutral and unavailable results remain recorded; reported coverage matters alongside accuracy.

## Learning

SPY and QQQ use `forecast-adaptive-v2`. Learning uses only completed v2 forecasts in the same horizon and outcomes received by the calculation timestamp. The live pulse keeps its unadjusted score until 60 eligible training sessions exist. Twenty earlier same-horizon returns, available before each forecast, provide its rolling sample volatility; zero or missing volatility excludes that training row. This requires at least 80 distinct sessions.

The target is `50 + 15 × clamp(return_pct / prior_20_session_sigma, -3, 3)`. A joint ridge regression fits residual corrections for news, market, calendar and earnings, with ridge penalty 8, a 60-session recency half-life and a total correction capped at 12 index points. The aggregate `score_delta` is excluded from adaptive and new shadow training. Correlated inputs are solved jointly; other horizons contribute zero weight. The correction does not establish calibrated probabilities or predictive skill.

New captures freeze the model version and evidence. Existing forecasts and outcomes are never rewritten. Legacy v1 outcomes remain visible individually but are excluded from v2 performance aggregates and training. Legacy probability candidates cannot attach to v2 captures. The morning window has shifted after the usual 08:30 releases; it requires a completed target-price bar no more than five minutes old, and never falls back to yesterday’s close. Delayed quotes may therefore skip a capture. Its actual baseline time is exposed; this remains a bar-based approximation, not an auction feed.

The separate daily probability-model experiment still uses chronological training, calibration and holdout blocks and compares candidates with a base-rate and a price-only model. Its stricter promotion gates do not block the adaptive index or live direction changes.

Candidate predictions are recorded prospectively. Promotion requires enough independent forward sessions, improved probability scores and acceptable calibration. A candidate's historical fit alone does not establish predictive value. Model versions and rejected candidates remain inspectable, and deteriorating candidates lose their promoted status.

## Active discovery

The crawler has its own persistent queue and runs independently of news publication. It reads configured feeds, explores publisher links, searches open research questions and reserves capacity for unrelated discovery. Browser scrolling is bounded and restricted to configured hosts. Robots restrictions and upstream failures are reported; a completed process does not imply complete source coverage.

Findings enter the raw evidence archive before classification. The existing headline classifier determines market relevance; discovery alone does not publish a story or issue an alert. Search matches remain evidence to assess, not proof that a question has been answered. Unknown publication dates stay unknown and are excluded from the predictive hot cache.

Article content versions, original arrival times, classification decisions and delivery attempts are durable. The seven-day JSON archive is only a hot cache. Existing raw records are migrated before expiration. Backend impact availability uses server receipt of the classification, with the classifier's own timestamp stored separately; late delivery cannot alter an earlier forecast.

## Research agent

`scripts/research-service/agent.mjs` runs on the Mini every five minutes. It calls the DeepSeek API directly (`deepseek-flash`) with tools for the Newswire data catalog, the Mini's seven-day raw headline archive, open-web news and web search, article reading through `/v1/extract`, and a Jev second opinion. The key is read as described in the README's DeepSeek section.

Open research questions are answered per event: the confirm and contradict halves share one verdict (`confirmed`, `contradicted`, `unresolved`), a likely market effect and cited sources, stored by `POST /v1/research/answers`. Unresolved events are retried after six hours while under two days old.

Predictions cover SPY, QQQ, IWM and DIA. They are accepted only in two windows: 8:40–9:25 a.m. Eastern (to the open, to the close) and the last 30 to 5 minutes of the session (to the next open, to the next close). `POST /v1/research/predictions` freezes the server's own completed five-minute price as the baseline and keeps one call per symbol, session, window and horizon. Settlement uses the opening bar's open or the closing bar's close. `GET /v1/research/agent?symbol=SPY` and the `agent` field of `GET /v1/research` report calls, outcomes, hit rate against always-up, Brier score against a coin flip and signal return. These are measurements, not evidence of an edge until many calls have settled.

`node scripts/research-service/agent.mjs --dry-run` runs both tasks without recording anything; outside the windows it rehearses late-session calls. `--only=answer` or `--only=predict` limits a run.

## Expert desk

`scripts/research-service/expert.mjs` writes one AI-generated feature per weekday after the close, rotating themes (Monday and Thursday: the AI trade; Tuesday: energy; Wednesday: banks and credit; Friday: the consumer). Code first fetches a price snapshot of the theme's basket (quote, day change, one-month and year-to-date returns) through the data tools; quotes older than four days are marked stale, and the run stops if fewer than half are current. The model then researches drivers with the same tools as the research agent plus screens, positioning and filings, and returns structured JSON. The story body is assembled by code: an AI-generated disclosure, key points, sections, what to watch, the deterministic price board and cited sources. The model never supplies the board's numbers.

It calls the DeepSeek API directly (`deepseek-flash`); `NEWSWIRE_EXPERT_MODEL` overrides the model. Stories use `agent: newswire-expert`, source `Newswire Expert (AI)`, tags `expert` and `ai-generated`, and external ID `expert:<theme>:<New York date>`; `~/.config/newswire/expert-state.json` skips a theme already published that day.

```sh
node scripts/research-service/expert.mjs --list
node scripts/research-service/expert.mjs --theme=ai --dry-run
node scripts/research-service/expert.mjs --topic="How the GLP-1 trade is developing" --tickers=LLY,NVO,AMGN,VKTX,HIMS --dry-run
```

`--force` reruns a theme already recorded for the day, but the server still returns the stored story for the same external ID. Custom topics accept `--key`, `--angle`, `--benchmarks` and `--category`. Install `newswire-expert.{service,timer}` with the other units.

## Operations

The systemd units in `scripts/research-service/` run on the Mini:

- `newswire-research.timer`: captures and settles every five minutes.
- `newswire-crawler.timer`: bounded discovery every ten minutes.
- `newswire-learning.timer`: candidate training and evaluation daily at 21:30 New York time.
- `newswire-agent.timer`: the research agent every five minutes.
- `newswire-expert.timer`: the expert feature at 16:40 New York time on weekdays.

These are separate from the minute-by-minute headline monitor. They use the existing protected writer-token mechanism. No token belongs in a unit, command argument, log or repository file. Browser dependencies are isolated under `scripts/crawler/`.

On the Fedora Mini, `bash scripts/research-service/prepare-browser.sh` extracts verified Fedora browser libraries into the user's data directory. The crawler unit uses that directory without changing system libraries or requiring administrator access. Install the crawler's locked Node dependencies and its Playwright Chromium runtime before enabling browsing.

For local checks, use Node 22 or newer and run `npm run typecheck` and `npm test` from `backend/`. The crawler supports `--once --dry-run` for inspection without archive writes. A frozen live snapshot is available from `GET /v1/market-pulse/snapshot?symbol=SPY`; this endpoint does not accept historical cutoffs.

Stop the three research timers to disable new research work. Restore the previous Worker version and backed-up Mini code if rollback is needed. Additive database tables preserve collected evidence and do not need to be deleted during code rollback.

## Audit follow-ups requiring further work

The revised historical backtest uses the 08:35 capture-price baseline; old prior-close correlations are not forward-alpha evidence. A new out-of-sample performance run has not been completed.

Calendar surprise residualization still needs a point-in-time reaction dataset and fitted coefficients. The heuristic pulse can still count a release and its price reaction together. Semantic event clustering, direct per-ticker Jev impacts, additional volatility/fuel/breadth inputs, official auction settlement, dynamic exchange calendars and historical consensus feeds remain follow-ups. No provider subscription or data migration is part of this patch. Do not assume that adding those signals improves predictive performance without chronological validation.
