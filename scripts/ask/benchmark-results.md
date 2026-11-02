# Discovery prompt validation — 2026-11-02 (Asia/Tokyo)

The discovery instructions and list formatting are implemented locally. **Answer-quality improvement is not measured yet.** Every attempted live comparison failed before the first model answer or tool call. Zero tool-call counts in these failed runs are not scores.

| Route | Result |
|---|---|
| DeepSeek direct | HTTP 402 |
| OpenCode Go subscription | HTTP 403 |
| Newswire server AI | Status endpoint reported available; actual completions returned HTTP 502 |
| OpenAI Responses | HTTP 429; a minimal generation probe confirmed `insufficient_quota` / `credit_balance_exhausted` |

The three paired questions were the user's exact low-attention request, a US/Europe/Japan discovery request, and a simple AAPL price control. OpenAI was configured with the same fixed `gpt-5.4-mini-2026-03-17` model, low reasoning effort and web search for both variants. This is not evidence about the user's selected ChatGPT model. The local reader credential returned 401; the existing writer credential succeeded for GET-only market-data access. No credentials were changed, and no market data was written.

Validation completed:

- Simulator build succeeded on the iPhone 17 Pro / iOS 27 QA simulator.
- All 15 focused `StockResearchTests` and `ChatGPTResponsesTests` passed, with zero skipped or failed tests. These test existing tool-loop, retry, cancellation and response handling; they do not evaluate model research quality.
- Opened `screenshots/ask-benchmark/research-layout.png`: a clearly marked synthetic ten-candidate answer renders its lead, caveats, citation chips and table. The wide table uses the existing horizontal scroll. This is a layout fixture, not a generated result. Only the visible upper rows were inspected.
- Benchmark script passes `node --check`; source whitespace checks passed.

Build attempts initially encountered a shared DerivedData lock and an unrelated concurrent portfolio-slider compilation failure. The final isolated build and test run passed after that separate source changed; this task did not edit the portfolio code.

Not verified: actual before/after candidate quality, broader retrieval compliance, attention evidence, degraded-provider reasoning, runtime latency, and the exact original interaction on the user's phone. No backend pricing, calendar, portfolio, or forecast calculations were changed; no production deployment or phone installation occurred.

Run instructions and the evaluation rubric are in `scripts/ask/README.md`. The saved pre-edit source and raw failure artifacts are in the gitignored `screenshots/ask-benchmark/` directory. The current prompt asks for broader research but does not programmatically enforce it or add new attention-data feeds.
