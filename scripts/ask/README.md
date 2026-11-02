# Ask discovery benchmark

Save the existing `ios/Sources/StockResearch.swift` before editing it, then compare it with the current working copy:

```sh
mkdir -p screenshots/ask-benchmark
cp ios/Sources/StockResearch.swift screenshots/ask-benchmark/StockResearch.before.swift
# Make the prompt changes, then:
node scripts/ask/benchmark.mjs \
  --before screenshots/ask-benchmark/StockResearch.before.swift \
  --provider openai --web \
  --out screenshots/ask-benchmark/openai
```

OpenAI uses `OPENAI_API_KEY` and a fixed `gpt-5.4-mini-2026-03-17` snapshot by default (`--model` overrides it). Other providers: `newswire` (the default, the app's server route), `deepseek`, and `go` (existing subscription route). The latter two reuse the credential handling in `scripts/ai/`. Credentials never go into result files. API runs consume the selected provider's quota; the script does not purchase credits or change accounts.

Data requests use `NEWSWIRE_READER_TOKEN` or the macOS Newswire `reader` Keychain entry. An existing writer credential can be selected with `--credential writer`; all market-data requests remain GET requests. `NEWSWIRE_URL` overrides the existing Worker origin. Use `--case low-attention`, `--case global`, or `--case quote` for a focused run.

The two variants use the same model settings, tool catalog, and a shared in-memory cache of tool responses. The script extracts the market prompt, answer format, widgets, discovery guidance, screen guidance and portfolio guidance from the actual Swift source. It records full public-data tool traces, source observations, answers, latency, token use, regions, explicitly queried sectors, individual company research and web-search calls. A single pair per question is a smoke comparison, not a statistically established improvement.

The harness limits research to 16 tool rounds and 60 calls. OpenAI uses Responses with low reasoning effort, a 6,000-output-token cap, and optional web search; other providers use the app's 1,800-token completion limit. Do not compare scores across providers or models. The app may select another ChatGPT model or use different defaults. This benchmark excludes the private portfolio, current-screen and native `stock_data` tools; the cases use the shared market-data tools. Web search remains live, so it is not a fully frozen replay. Concurrent variants share data responses, but latency is diagnostic, not an isolated speed measurement.

Review the answers and traces together:

- **Low attention:** Did it explore beyond the momentum preset, inspect companies individually, compare matching-period benchmarks, and seek actual attention evidence? Are unsupported candidates explicitly unverified or omitted? A missing or capped news result must never count as proof of low attention.
- **Global:** Did it actually query US, European and Japanese markets and examine multiple sectors? Are returns comparable, and do cited sources support the drivers?
- **Quote control:** Does it still answer a simple price question directly, with its observation time, without a discovery sweep?
- For all cases, inspect failures, stale observations, missing baselines, currencies and return basis. More tool calls or longer answers are not quality scores. Do not infer market-wide coverage from the number of returned candidates.

Artifacts are written to the gitignored `screenshots/` directory. `summary.json` contains metrics and answers, individual JSON files contain the traces, and `tool-snapshot.json` records shared data. Failed requests have an `error` and the process exits nonzero; no empty run is a scored answer.

## Simulator layout preview

A Debug build launched with `-askResearchPreview` loads `[StockChatMessage]` JSON from its Documents directory at `ask-research-preview.json`. Each message needs an `id` UUID, `user` boolean and `text`; `sources`, `provider` and `options` are optional. Use this to inspect an actual benchmark answer or a clearly marked synthetic layout fixture. A layout fixture is not evidence of model quality.
