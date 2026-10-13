# Newswire source priorities

Reviewed October 13, 2026. Bellingcat RSS is now enabled in headline intake and the research crawler. UKMTO and ISW have Google News discovery feeds in headline intake: UKMTO returned three entries in the live check; ISW returned zero, so its current coverage is not proven. Direct UKMTO and ISW retrieval returned HTTP 403. Other additions below remain planned.

The current headline configuration already includes Reuters and AP discovery through Google News, BBC, NPR, Guardian, Al Jazeera, CNBC, FT, NYT, Yahoo Finance, Seeking Alpha, Federal Reserve, BEA, ECB, EIA, gCaptain and FreightWaves. More finance feeds alone would amplify the current imbalance. Start with geopolitical events, primary evidence and company-specific disclosures.

| Priority | Source | What it adds | Proposed intake and limits |
| --- | --- | --- | --- |
| 1 | [UK Maritime Trade Operations](https://www.ukmto.org/ukmto-products) | Maritime warnings, advisories and incident updates relevant to Hormuz, the Red Sea, shipping and energy | Poll official warning/advisory indexes; track incident IDs and corrections. A report of an incident is not independent confirmation of the actor responsible. |
| 1 | [Institute for the Study of War / Critical Threats](https://understandingwar.org/research/) | Iran and other conflict assessments, with cited evidence | Ingest dated research updates as attributed analysis. The research index was search-visible but direct retrieval returned 403 during this review; validate an accessible supported intake before enabling. |
| 1 | [SEC EDGAR](https://www.sec.gov/about/developer-resources) plus held companies' investor-relations releases | Filings and material corporate announcements tied to actual holdings | Reuse existing SEC infrastructure; prioritize held-company 8-K/6-K filings and earnings/guidance releases. Map CIK and company identity to portfolio symbols. Official filing availability does not itself imply materiality. |
| 2 | [Bellingcat](https://www.bellingcat.com/resources) | Open-source investigations and verification methods | Add investigations as evidence/context; keep tutorials and tools out of the breaking-news stream. Follow links to the original evidence. |
| 2 | [ACLED](https://acleddata.com/api-documentation/getting-started) | Structured political violence, demonstrations and strategic-development events | A myACLED account and authenticated API access are required. Confirm permitted access and update cadence first; use for trend corroboration, not minute-by-minute alerts. |
| 2 | [ReliefWeb](https://apidoc.reliefweb.int/) | Humanitarian reporting and situation reports from multiple organizations | API requires a pre-approved appname; public RSS returned HTTP 406. Not enabled. Preserve the originating organization; multiple mirrors of one report count as one source. |
| 2 | [GDELT](https://blog.gdeltproject.org/gdelt-doc-2-0-api-debuts/) | Multilingual discovery and breadth of coverage across outlets | Already enabled in crawler discovery. Improve event clustering and original-publisher attribution before using coverage counts for ranking. Coverage is attention, not truth or measured readership; handle rate limits and missing results explicitly. |

Reuters/AP and the existing general-news sources should remain the baseline for timely independent reporting. Keep Seeking Alpha for relevant company developments; source-wide suppression would also bury useful earnings or dividend-cut news about a holding. Avoid adding Bloomberg direct feeds again without a supported access path.

## Ranking policy

1. Major, time-sensitive developments with broad consequences: conflict escalation/de-escalation, shipping disruption, systemic financial stress, major policy decisions and economic releases.
2. Material news about held companies, followed by watched companies. Use explicit ticker references and known company names; do not invent indirect portfolio exposure from a vague sector association.
3. Significant independently covered events. Normalize publisher names and count each publisher once; cap the coverage boost. Syndicated copies must not be presented as independent confirmation.
4. Other fresh reporting and substantive analysis.
5. Routine dividend declarations, ex-dividend reminders and generic stock-outlook pieces unrelated to holdings. Keep them accessible. Dividend cuts/suspensions and other material changes need different treatment from routine payouts.

Freshness decays all scores. An old crisis should not pin the feed forever. Merge new arrivals into the ranked feed only when the reader is at the top; append ranked older batches without moving the rows being read. Search retains its existing ordering.

Current implementation ranks a bounded local candidate window, not every story in the archive. Cross-source title overlap is a coverage heuristic, not a popularity metric or verified event cluster. A future backend event index should preserve original source attribution, event time, update/correction links, confidence and concrete transmission channels (for example a shipping disruption affecting oil supply). Keep news importance separate from push-alert urgency and from investment recommendations.

## Market analysis handoff

Headline intake archives source material before topic filtering. The impact queue prioritizes confidently classified systemic events, then material company events, then unclassified reporting, then routine company updates. This changes processing order, not predicted market direction. The separate impact classifier must identify a concrete market channel and confidence before publishing an impact to `/v1/market-pulse/impacts`.

The scheduled research crawler also runs this handoff after archiving discoveries and uploading its discovery report. It retains original publication, first-observed and classification times, source and URL. Failed deliveries remain retryable, successful deliveries are not resent, and capture/forecast jobs read the resulting production pulse inputs. Existing Worker endpoints support this contract; no Worker schema or scoring deployment is required for this release.

Headline classification handles up to 16 pending items per monitor pass and checkpoints every eight results. This keeps scheduled runs bounded and preserves paid classifier work if a later source or request fails. Jev request encoding repairs truncated Unicode before transmission.
