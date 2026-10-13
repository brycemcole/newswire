# Market research

Newswire saves experimental SPY and QQQ forecasts and evaluates them after their target period. The initial score is an index. It is not a probability, a promised return, or evidence of a trading edge.

## Forecast ledger

The writer calls `POST /v1/research/capture` with `{"symbol":"SPY"}`. The server captures its own current pulse, classified news, calendar observations, market inputs, target-price evidence and hashes. Clients cannot backdate a forecast or supply its evidence.

Capture windows use New York time and the exchange session calendar:

| Window | Target |
| --- | --- |
| 07:00–07:15 | Opening gap from the previous session close |
| 09:25–09:30 | Open-to-close return |
| Last 15 minutes of the session | Remaining move from the observed price to the next session open |

One forecast is retained per symbol, target session and horizon. Repeated requests do not replace it. Outside a window the request returns a skip. Missing or stale required prices cannot become an invented baseline. Unexpected exchange closures still require calendar maintenance.

`POST /v1/research/settle` fetches Yahoo market data on the server and settles mature forecasts once. Completed five-minute bars approximate session endpoints; provider delays and later historical corrections remain limitations. Outcomes and their source timestamps remain separate from forecast evidence.

Authenticated readers use `GET /v1/research?symbol=SPY`. The native Market Pulse detail has a Research link showing recorded forecasts, outcomes, source discovery, open questions and evidence. Performance is separated by horizon. Neutral and unavailable results remain recorded; reported coverage matters alongside accuracy.

## Learning

SPY and QQQ use `forecast-adaptive-v1` immediately. Every live refresh and scheduled capture reads up to 180 completed forecasts for that symbol, using only outcomes received by the calculation timestamp. There is no minimum-day gate. Research shows this live reading separately from the immutable saved forecast and refreshes while visible every minute.

Completed outcomes adjust the existing signal weights toward a directional target index (35 down, 50 flat, 65 up). The adjustment has eight units of prior support, a ten-session half-life, quarter weight for other forecast periods, and normalization within each session. Coefficients stay between zero and twice their original weights, and the total correction is capped at 12 index points. These are heuristic learning choices, not fitted return probabilities. Small samples have small influence; repeated runs add no observations. New captures freeze the weights and support with their evidence. Existing forecasts and outcomes are never rewritten.

The separate daily probability-model experiment still uses chronological training, calibration and holdout blocks and compares candidates with a base-rate and a price-only model. Its stricter promotion gates do not block the adaptive index or live direction changes.

Candidate predictions are recorded prospectively. Promotion requires enough independent forward sessions, improved probability scores and acceptable calibration. A candidate's historical fit alone does not establish predictive value. Model versions and rejected candidates remain inspectable, and deteriorating candidates lose their promoted status.

## Active discovery

The crawler has its own persistent queue and runs independently of news publication. It reads configured feeds, explores publisher links, searches open research questions and reserves capacity for unrelated discovery. Browser scrolling is bounded and restricted to configured hosts. Robots restrictions and upstream failures are reported; a completed process does not imply complete source coverage.

Findings enter the raw evidence archive before classification. The existing headline classifier determines market relevance; discovery alone does not publish a story or issue an alert. Search matches remain evidence to assess, not proof that a question has been answered. Unknown publication dates stay unknown and are excluded from the predictive hot cache.

Article content versions, original arrival times, classification decisions and delivery attempts are durable. The seven-day JSON archive is only a hot cache. Existing raw records are migrated before expiration. Backend impact availability uses server receipt of the classification, with the classifier's own timestamp stored separately; late delivery cannot alter an earlier forecast.

## Operations

The systemd units in `scripts/research-service/` run on the Mini:

- `newswire-research.timer`: captures and settles every five minutes.
- `newswire-crawler.timer`: bounded discovery every ten minutes.
- `newswire-learning.timer`: candidate training and evaluation daily at 21:30 New York time.

These are separate from the minute-by-minute headline monitor. They use the existing protected writer-token mechanism. No token belongs in a unit, command argument, log or repository file. Browser dependencies are isolated under `scripts/crawler/`.

On the Fedora Mini, `bash scripts/research-service/prepare-browser.sh` extracts verified Fedora browser libraries into the user's data directory. The crawler unit uses that directory without changing system libraries or requiring administrator access. Install the crawler's locked Node dependencies and its Playwright Chromium runtime before enabling browsing.

For local checks, use Node 22 or newer and run `npm run typecheck` and `npm test` from `backend/`. The crawler supports `--once --dry-run` for inspection without archive writes. A frozen live snapshot is available from `GET /v1/market-pulse/snapshot?symbol=SPY`; this endpoint does not accept historical cutoffs.

Stop the three research timers to disable new research work. Restore the previous Worker version and backed-up Mini code if rollback is needed. Additive database tables preserve collected evidence and do not need to be deleted during code rollback.
