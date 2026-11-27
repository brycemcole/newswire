# Do headline features beat price-only on held-out dates?

**Not established.** The existing learning pipeline has **zero held-out test dates** in the available data. A descriptive comparison of stored forward calls shows no positive hit-rate improvement, but is neither a frozen-model holdout nor a controlled headline-feature ablation. Do not interpret this as proof that headlines help, hurt, or have no value.

Read-only inspection: **2026-11-17, approximately 09:25–09:30 UTC**, using code at `34e83ec`. No capture, settlement, fitting, tuning, registration, or promotion endpoints were invoked.

## Data, coverage, and abstentions

The production `GET /v1/research/diagnostics?symbol=SPY|QQQ` responses contain **99 settled forecasts over 19 distinct target-session dates**, spanning **2026-10-16–2026-11-16**. Symbols and horizons are not independent dates. There are no duplicate forecast IDs or zero-direction outcomes in these responses.

The existing `sessionFor` calendar in `backend/src/forecast.ts` gives **22 exchange sessions** in that interval: settled-date coverage is **19/22 (86.4%)**. Across two symbols and three horizons, settled-record coverage is **99/132 (75.0%)**. These are settlement/export completeness measures, not ingestion uptime. Diagnostics joins outcomes and filters compatible model versions; it cannot distinguish uncaptured, unsettled, or incompatible-version records. October 23, 28, and 29 have no returned settled records for either symbol.

| Symbol | Horizon | Distinct dates / 22 | News available / rows | Market available / rows | Directional calls / rows | Neutral abstentions |
|---|---|---:|---:|---:|---:|---:|
| SPY | opening_gap | 17 | 15/17 | 17/17 | 14/17 | 3 |
| SPY | cutoff_to_open | 15 | 12/15 | 15/15 | 15/15 | 0 |
| SPY | open_to_close | 17 | 15/17 | 17/17 | 14/17 | 3 |
| QQQ | opening_gap | 17 | 15/17 | 17/17 | 15/17 | 2 |
| QQQ | cutoff_to_open | 16 | 13/16 | 16/16 | 14/16 | 2 |
| QQQ | open_to_close | 17 | 15/17 | 17/17 | 16/17 | 1 |

Overall: `news_available=1` on **85/99 (85.9%)**, `market_available=1` on **99/99**, and **11/99 neutral abstentions (11.1%)**; no returned row has `tilt=unavailable`. News unavailability is not neutral news. The frozen `price_only_direction` calls on all 99 rows. Neither input availability flag certifies complete/fresh underlying feeds. Missing records are not counted as abstentions.

## Held-out support: insufficient

Reused `evaluateLearning` in `scripts/market-pulse/learning.mjs` on the exported `open_to_close` training rows (17 per symbol). Both return `eligible: false`, reason **insufficient chronological train/calibration/test support**.

The existing date-grouped 60/20/20 split, with five-session gaps around boundaries, leaves **5 training / 0 calibration / 0 test dates** for each symbol. Applying the same splitter to diagnostics gives 5/0/0 for opening_gap and 4/0/0 for cutoff_to_open. No random row split or shorter embargo was substituted to manufacture a holdout.

The learning gate requires **180 training, 60 calibration, and 60 test dates per symbol/horizon**. With its present fractions and gaps, 350 fully usable distinct dates would give 205/60/65; current groups have only 15–17. All six `GET /v1/research/candidates?symbol=…&horizon=…` responses contain **zero candidates**, so there is no registered candidate's prospective paired-probability evaluation to use instead.

**Held-out headline-versus-price Brier difference and bootstrap CI: unavailable (0 held-out dates), not zero.**

## Descriptive metric and bootstrap uncertainty — not held-out evidence

For context only, compare the stored combined model's `tilt` (up = +1; down = −1) with the **stored**, not reconstructed, `price_only_direction`, the frozen sign of market-only pulse points at capture. Retain settled rows where both issue a directional call. The metric is combined hit rate minus price-only hit rate on those **same dates**. Neutral calls are excluded from both numerators/denominators, so this does not measure abstention quality or whole-strategy returns.

| Symbol | Horizon | Paired dates | Combined hits | Price-only hits | Difference, percentage points | 95% paired date-bootstrap interval |
|---|---|---:|---:|---:|---:|---:|
| SPY | opening_gap | 14 | 5/14 | 5/14 | 0.0 | [0.0, 0.0] |
| SPY | cutoff_to_open | 15 | 4/15 | 5/15 | −6.7 | [−20.0, 0.0] |
| SPY | open_to_close | 14 | 8/14 | 8/14 | 0.0 | [0.0, 0.0] |
| QQQ | opening_gap | 15 | 7/15 | 7/15 | 0.0 | [0.0, 0.0] |
| QQQ | cutoff_to_open | 14 | 3/14 | 3/14 | 0.0 | [0.0, 0.0] |
| QQQ | open_to_close | 16 | 10/16 | 10/16 | 0.0 | [0.0, 0.0] |

Method: **20,000 resamples**, independently within each symbol/horizon, sampling paired session dates with replacement and retaining both predictions together. Statistic: mean of `I(combined_direction == direction) − I(price_only_direction == direction)`. Percentile endpoints are sorted replicate indices 499 and 19,499 (zero-based). Deterministic PRNG: initial unsigned seed 20261117, updated as `(1664525 × seed + 1013904223) mod 2^32`; uniform = seed / 2^32. Traversal order is SPY then QQQ, each opening_gap, cutoff_to_open, open_to_close, dates ascending, continuing the generator across groups. No cross-group pooling.

The degenerate [0,0] intervals arise because paired correctness differences are zero on every included date in those groups. They **do not establish population equivalence**. This small-sample bootstrap conditions on observed calls, ignores longer-run serial dependence and model-development selection, and cannot quantify missing-date bias. The sole nonzero comparison is one additional SPY cutoff_to_open error; its interval also includes zero. These six descriptive comparisons were not used to select a winner.

## Why existing backtests do not answer the question

- `scripts/market-pulse/backtest-market.mjs` and the local `.build-market-pulse/backtest-market.json` cover **59 price-data sessions**, July 29–October 20. Their variants drop/add **market inputs**, not headlines, and do not reserve held-out dates. They cannot supply a headline ablation.
- Both archived October 12 replay reports explicitly identify themselves as the **same selected retrospective session**, using rules developed after the outcome. Duplicated reports, hourly snapshots, and story arrivals are not extra independent dates. The October 13 official outlook is a forward snapshot without paired outcome evaluation in that artifact.
- Regression fixtures in `backend/test/fixtures` and the backtest gate protect code behavior; they are not an independently reserved headline-versus-price test set.
- Stored combined calls include earnings/calendar effects and evolving parameters. Even a significant combined-versus-market difference would not isolate headline features. The learning script's full-versus-price feature sets likewise differ by more than news alone.

## Exactly what is missing / next valid comparison

1. Enough temporally valid, settled **distinct dates per symbol/horizon** to populate the existing chronological split and support thresholds; recover/characterize missing captures and settlements without inventing availability.
2. A frozen, documented comparison that differs **only by headline features**, holding price features, other components, fitting procedure, calibration, target horizon, and coverage/abstention policy constant.
3. Predictions from both versions recorded before outcomes on untouched dates, with model/input versions and capture/target timestamps, followed by valid baseline/endpoint prices and settled outcomes. Candidate registrations and prospective predictions are presently absent.
4. Report held-out Brier improvement (lower is better), paired date/block-bootstrap uncertainty, coverage, and abstentions on a common eligible population. Do not retune on those test outcomes.

**Conclusion: no demonstrated held-out headline edge. The available descriptive calls show no positive incremental directional accuracy; the requested held-out feature claim remains inconclusive.**

### Audit trail

Sources: read-only production diagnostics, training (`open_to_close`), and candidate GET endpoints above; existing learning/split/calendar code; local replay/backtest archives; `MARKET_PULSE.md`. Raw responses remain gitignored under `.build-market-pulse/readout/` in the readout worktree, not committed. SHA-256 of the pretty-printed archived diagnostics responses (no trailing newline):

- SPY: `773fa1ad21a24c8d2e63fbd83d6d43842751d2fdc9edfd5b8892a1ac07018945`
- QQQ: `418f1264b2adad13f7335634858befd31d88c3de3449685ba85a9f10276559b5`

These endpoints are mutable; later exports can differ. No credentials are included. Verification comprised live GETs, execution of the existing learning/split/calendar functions, and the paired bootstrap calculation; no application behavior changed and no UI screenshots or test suite were needed.
