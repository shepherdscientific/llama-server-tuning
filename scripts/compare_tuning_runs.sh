#!/usr/bin/env bash
set -euo pipefail

left_tsv=""
right_tsv=""
left_label="left"
right_label="right"
output=""

usage() {
  cat <<'EOF'
Usage: compare_tuning_runs.sh --left TSV --right TSV [options]

Compares two tuning summary TSV files produced by tune_qwen_server.sh and writes
a side-by-side Markdown report.

Options:
  --left TSV           Left summary TSV
  --right TSV          Right summary TSV
  --left-label NAME    Label for left side (default: left)
  --right-label NAME   Label for right side (default: right)
  --output FILE        Output markdown path (default: alongside left TSV)
  -h, --help           Show this help

Example:
  compare_tuning_runs.sh \
    --left tuning-results/turbo-20260403-120000/turbo-summary.tsv \
    --right tuning-results/f16-20260403-121500/f16-summary.tsv \
    --left-label turbo \
    --right-label f16
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --left)
      left_tsv=$2
      shift 2
      ;;
    --right)
      right_tsv=$2
      shift 2
      ;;
    --left-label)
      left_label=$2
      shift 2
      ;;
    --right-label)
      right_label=$2
      shift 2
      ;;
    --output)
      output=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$left_tsv" || -z "$right_tsv" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$output" ]]; then
  output="$(dirname "$left_tsv")/compare-${left_label}-vs-${right_label}.md"
fi

python3 - "$left_tsv" "$right_tsv" "$left_label" "$right_label" "$output" <<'PY'
import csv
import pathlib
import sys

left_tsv, right_tsv, left_label, right_label, output = sys.argv[1:]

def load_rows(path):
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            rows.append(row)
    return rows

def key(row):
    return (row["ctx_size"], row["batch_size"], row["ubatch_size"])

def f(row, field):
    try:
        return float(row[field])
    except Exception:
        return None

left_rows = load_rows(left_tsv)
right_rows = load_rows(right_tsv)

left_ok = {key(r): r for r in left_rows if r["status"] == "ok"}
right_ok = {key(r): r for r in right_rows if r["status"] == "ok"}
all_keys = sorted(set(left_ok) | set(right_ok), key=lambda k: tuple(int(x) for x in k))

lines = []
lines.append(f"# Tuning Comparison: {left_label} vs {right_label}")
lines.append("")
lines.append(f"- Left TSV: `{left_tsv}`")
lines.append(f"- Right TSV: `{right_tsv}`")
lines.append(f"- Comparable healthy configs: {sum(1 for k in all_keys if k in left_ok and k in right_ok)}")
lines.append("")

def top_by(rows_dict, field, reverse=True, n=5):
    items = [(k, r) for k, r in rows_dict.items() if f(r, field) is not None]
    items.sort(key=lambda item: f(item[1], field), reverse=reverse)
    return items[:n]

lines.append("## Best Configs By Completion tok/s")
lines.append("")
for label, rows_dict in [(left_label, left_ok), (right_label, right_ok)]:
    lines.append(f"### {label}")
    lines.append("")
    lines.append("| ctx | batch | ubatch | completion tok/s | total tok/s | wall s | avg RSS MiB | peak RSS MiB |")
    lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|")
    for (_, row) in top_by(rows_dict, "avg_completion_tok_s", reverse=True, n=5):
        lines.append(
            f"| {row['ctx_size']} | {row['batch_size']} | {row['ubatch_size']} | "
            f"{row['avg_completion_tok_s']} | {row['avg_total_tok_s']} | {row['avg_wall_s']} | "
            f"{row['avg_rss_mb']} | {row['peak_rss_mb']} |"
        )
    lines.append("")

lines.append("## Matching Config Comparison")
lines.append("")
lines.append(
    f"| ctx | batch | ubatch | {left_label} completion tok/s | {right_label} completion tok/s | "
    f"delta % ({right_label} vs {left_label}) | {left_label} avg RSS | {right_label} avg RSS | "
    f"RSS delta % ({right_label} vs {left_label}) |"
)
lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")

for k in all_keys:
    if k not in left_ok or k not in right_ok:
        continue
    l = left_ok[k]
    r = right_ok[k]
    l_ctps = f(l, "avg_completion_tok_s")
    r_ctps = f(r, "avg_completion_tok_s")
    l_rss = f(l, "avg_rss_mb")
    r_rss = f(r, "avg_rss_mb")
    delta_ctps = ((r_ctps / l_ctps) - 1.0) * 100.0 if l_ctps else None
    delta_rss = ((r_rss / l_rss) - 1.0) * 100.0 if l_rss else None
    lines.append(
        f"| {k[0]} | {k[1]} | {k[2]} | {l['avg_completion_tok_s']} | {r['avg_completion_tok_s']} | "
        f"{delta_ctps:+.2f}% | {l['avg_rss_mb']} | {r['avg_rss_mb']} | {delta_rss:+.2f}% |"
    )

lines.append("")
lines.append("## Fastest Winner Per Matching Config")
lines.append("")
lines.append("| ctx | batch | ubatch | winner | winner completion tok/s | loser completion tok/s | memory-friendlier side |")
lines.append("|---:|---:|---:|---|---:|---:|---|")
for k in all_keys:
    if k not in left_ok or k not in right_ok:
        continue
    l = left_ok[k]
    r = right_ok[k]
    l_ctps = f(l, "avg_completion_tok_s")
    r_ctps = f(r, "avg_completion_tok_s")
    l_rss = f(l, "avg_rss_mb")
    r_rss = f(r, "avg_rss_mb")
    winner = left_label if l_ctps >= r_ctps else right_label
    winner_ctps = l_ctps if l_ctps >= r_ctps else r_ctps
    loser_ctps = r_ctps if l_ctps >= r_ctps else l_ctps
    mem_winner = left_label if l_rss <= r_rss else right_label
    lines.append(f"| {k[0]} | {k[1]} | {k[2]} | {winner} | {winner_ctps:.2f} | {loser_ctps:.2f} | {mem_winner} |")

pathlib.Path(output).write_text("\n".join(lines) + "\n", encoding="utf-8")
print(output)
PY
