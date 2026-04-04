# llama-server-tuning

Benchmarking and tuning helpers for `llama-server` on local inference machines.

This repo grew out of a practical question: when running the same Qwen model on the same custom-built `llama-server`, do alternative KV cache strategies improve throughput, reduce memory pressure, or make larger context windows more practical?

The initial surprise was that the compressed/turbo KV path did not obviously win at moderate prompt sizes. On the tested M4 Pro machine, `f16` KV remained faster, while the compressed path used somewhat less memory. That shifted the focus from "is it faster?" to the more useful question: "at what context length does the memory tradeoff become worth it?"

## What is here

- `scripts/benchmark_qwen.sh`
  Single-endpoint and two-endpoint benchmark helper for OpenAI-compatible `llama-server` endpoints.
- `scripts/benchmark_qwen_stepwise.sh`
  One-at-a-time stepped benchmark runner for comparing two launcher scripts without endpoint contention.
- `scripts/tune_qwen_server.sh`
  Sweeps `--ctx-size`, `--batch-size`, and `--ubatch-size`, health-checks each config, benchmarks stable ones, and writes machine-readable plus markdown summaries. It can also derive prompt size from a target fraction of each tested context window.
- `scripts/compare_tuning_runs.sh`
  Compares two tuning summary TSV files and writes a side-by-side markdown report.

## Why one-at-a-time benchmarking matters

Running two large servers side by side makes it too easy to measure contention instead of model behavior. This is easy to do on any shared local inference machine, and the same benchmarking trap shows up across local inference setups too. The later scripts in this repo intentionally run a single server at a time, wait for it to become healthy, benchmark it, stop it, and only then move to the next config.

## Typical workflow

1. Build or point at your desired `llama-server` binary.
2. Tune one KV strategy:

```bash
./scripts/tune_qwen_server.sh \
  --label f16 \
  --cache-type-k f16 \
  --cache-type-v f16
```

3. Tune the other KV strategy:

```bash
./scripts/tune_qwen_server.sh \
  --label turbo \
  --cache-type-k turbo3 \
  --cache-type-v turbo3 \
  --ctx-fill-ratio 0.80
```

4. Compare the resulting summaries:

```bash
./scripts/compare_tuning_runs.sh \
  --left tuning-results/turbo-YYYYMMDD-HHMMSS/turbo-summary.tsv \
  --right tuning-results/f16-YYYYMMDD-HHMMSS/f16-summary.tsv \
  --left-label turbo \
  --right-label f16
```

## Results

The published Apple Silicon result bundle is under [`results/apple-silicon`](./results/apple-silicon). Start with the comparison writeups and max-context summary:

- [Pair 1 comparison](./results/apple-silicon/turbo-20260403-130143/compare-turbo-vs-f16.md)
- [Pair 2 comparison](./results/apple-silicon/turbo-20260403-153548/compare-turbo-vs-f16.md)
- [Turbo max-context summary](./results/apple-silicon/turbo-maxctx-20260403-165708/turbo-maxctx-summary.md)
- [Source provenance](./results/apple-silicon/source-provenance.md)
- [Architecture-scoped plots](./results/apple-silicon/plots/aggregate/README.md)

### Highlights from the published runs

- Fastest published `f16` config: `ctx=131072`, `batch=1024`, `ubatch=128` at `34.39` completion tok/s with `49928.8 MiB` average RSS.
- Fastest published turbo config: `ctx=98304`, `batch=1024`, `ubatch=128` at `29.18` completion tok/s with `47306.0 MiB` average RSS.
- Most memory-efficient published `f16` config: `ctx=32768`, `batch=512`, `ubatch=128` at `47612.7 MiB` average RSS.
- Most memory-efficient published turbo config: `ctx=32768`, `batch=1024`, `ubatch=128` at `47003.7 MiB` average RSS.
- Published max-context turbo sweep remained healthy through `ctx=245760`; the fastest max-context setting there was `ctx=196608`, `batch=512`, `ubatch=128` at `5.16` completion tok/s with `48713.7 MiB` average RSS.

## Notes

- If your active `llama-server` binary does not support a given cache type, the tuning sweep will fail health checks quickly. That is still useful because it tells you the config is not viable with that binary.
- Throughput at small or moderate prompt sizes can be a misleading proxy for long-context behavior.
- The most interesting comparisons are often at progressively larger prompt sizes, where memory pressure, checkpointing, and stability become the dominant factors.

## Publishing checklist

## License

This repository is licensed under GPL-3.0.

Before publishing results, it helps to include:

- exact `llama-server` commit
- model name and quant
- machine specs
- whether prompt cache was enabled or disabled
- whether runs were one-at-a-time or concurrent
- prompt size strategy
- failure modes, not just the fastest successful run
