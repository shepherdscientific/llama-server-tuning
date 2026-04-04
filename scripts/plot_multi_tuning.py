#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt


def load_best_rows(path, metric, lower_is_better=False):
    best = {}
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            if row.get("status") != "ok":
                continue
            try:
                ctx = int(row["ctx_size"])
                row["ctx_size"] = ctx
                row["batch_size"] = int(row["batch_size"])
                row["ubatch_size"] = int(row["ubatch_size"])
                row["avg_completion_tok_s"] = float(row["avg_completion_tok_s"])
                row["avg_total_tok_s"] = float(row["avg_total_tok_s"])
                row["avg_wall_s"] = float(row["avg_wall_s"])
                row["avg_rss_mb"] = float(row["avg_rss_mb"])
                row["peak_rss_mb"] = float(row["peak_rss_mb"])
            except Exception:
                continue
            cur = best.get(ctx)
            if cur is None:
                best[ctx] = row
            else:
                if lower_is_better:
                    if row[metric] < cur[metric]:
                        best[ctx] = row
                else:
                    if row[metric] > cur[metric]:
                        best[ctx] = row
    return dict(sorted(best.items()))


def parse_series_arg(value):
    if "=" not in value:
        raise ValueError(f"Invalid --series '{value}', expected LABEL=PATH")
    label, path = value.split("=", 1)
    return label, path


def plot_metric(series_defs, metric, ylabel, title, out_path, lower_is_better=False):
    plt.figure(figsize=(10, 5.5))
    for label, path in series_defs:
        rows = load_best_rows(path, metric, lower_is_better=lower_is_better)
        if not rows:
            continue
        xs = list(rows.keys())
        ys = [rows[x][metric] for x in xs]
        plt.plot(xs, ys, marker="o", linewidth=2, label=label)
    plt.title(title)
    plt.xlabel("ctx_size")
    plt.ylabel(ylabel)
    plt.grid(True, alpha=0.25)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_path, dpi=160)
    plt.close()


def write_index(series_defs, output_dir, outputs):
    lines = [
        "# Aggregate Tuning Plots",
        "",
        "## Included series",
        "",
    ]
    for label, path in series_defs:
        lines.append(f"- `{label}`: `{path}`")
    lines.extend([
        "",
        "## Generated plots",
        "",
    ])
    for name in outputs:
        lines.append(f"- ![{name}]({name})")
    Path(output_dir, "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--series", action="append", required=True, help="LABEL=PATH to a tuning summary TSV; repeatable")
    ap.add_argument("--output-dir", required=True)
    args = ap.parse_args()

    series_defs = [parse_series_arg(v) for v in args.series]
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    outputs = []
    p = out_dir / "completion_tok_s.png"
    plot_metric(series_defs, "avg_completion_tok_s", "completion tok/s", "Best completion tok/s by ctx_size", p)
    outputs.append(p.name)

    p = out_dir / "total_tok_s.png"
    plot_metric(series_defs, "avg_total_tok_s", "total tok/s", "Best total tok/s by ctx_size", p)
    outputs.append(p.name)

    p = out_dir / "avg_rss_mb.png"
    plot_metric(series_defs, "avg_rss_mb", "avg RSS MiB", "Lowest avg RSS by ctx_size", p, lower_is_better=True)
    outputs.append(p.name)

    p = out_dir / "avg_wall_s.png"
    plot_metric(series_defs, "avg_wall_s", "wall seconds", "Lowest avg wall time by ctx_size", p, lower_is_better=True)
    outputs.append(p.name)

    write_index(series_defs, out_dir, outputs)


if __name__ == "__main__":
    main()
