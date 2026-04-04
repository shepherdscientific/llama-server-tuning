# Results

This directory contains selected benchmark and tuning artifacts copied from the original working project, plus generated comparison plots.

## Included run folders

- `intellyvest/f16-20260403-120306`
- `intellyvest/turbo-20260403-130143`
- `intellyvest/f16-20260403-140703`
- `intellyvest/turbo-20260403-153548`

## Generated comparisons

- [Pair 1 graphs](./plots/pair-1/turbo-vs-f16-graphs.md)
  First comparison set.
- [Pair 2 graphs](./plots/pair-2/turbo-vs-f16-graphs.md)
  Second comparison set.

The generated SVG plots show:
- best completion tokens/sec by `ctx_size`
- lowest RSS by `ctx_size`

These reports are intended to accompany the TSV summaries, not replace them.

- [Aggregate plots](./plots/aggregate/README.md)
  Combined view across pair-1, pair-2, and turbo-maxctx.
