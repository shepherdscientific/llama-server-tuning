#!/usr/bin/env python3
import argparse
import csv
import html
from pathlib import Path


def load_rows(path):
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            if row.get("status") != "ok":
                continue
            try:
                row["ctx_size"] = int(row["ctx_size"])
                row["batch_size"] = int(row["batch_size"])
                row["ubatch_size"] = int(row["ubatch_size"])
                row["avg_completion_tok_s"] = float(row["avg_completion_tok_s"])
                row["avg_total_tok_s"] = float(row["avg_total_tok_s"])
                row["avg_wall_s"] = float(row["avg_wall_s"])
                row["avg_rss_mb"] = float(row["avg_rss_mb"])
                row["peak_rss_mb"] = float(row["peak_rss_mb"])
            except Exception:
                continue
            rows.append(row)
    return rows


def best_by_ctx(rows, metric):
    best = {}
    for row in rows:
        ctx = row["ctx_size"]
        current = best.get(ctx)
        if current is None:
            best[ctx] = row
            continue
        if metric == "avg_rss_mb":
            if row[metric] < current[metric]:
                best[ctx] = row
        else:
            if row[metric] > current[metric]:
                best[ctx] = row
    return dict(sorted(best.items()))


def svg_line_chart(series_map, title, y_label, width=900, height=360):
    all_points = []
    for _, pts in series_map.items():
        all_points.extend(pts)
    if not all_points:
        return "<svg xmlns='http://www.w3.org/2000/svg' width='900' height='120'></svg>"

    xs = [p[0] for p in all_points]
    ys = [p[1] for p in all_points]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    if max_x == min_x:
        max_x += 1
    if max_y == min_y:
        max_y += 1

    margin_left = 70
    margin_right = 20
    margin_top = 40
    margin_bottom = 50
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom

    def sx(x):
        return margin_left + (x - min_x) * plot_w / (max_x - min_x)

    def sy(y):
        return margin_top + plot_h - (y - min_y) * plot_h / (max_y - min_y)

    colors = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e"]
    parts = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>",
        "<style>text{font-family:Arial,sans-serif;font-size:12px;fill:#222}.title{font-size:16px;font-weight:bold}.axis{stroke:#333;stroke-width:1}.grid{stroke:#ddd;stroke-width:1}.pt{stroke:white;stroke-width:1.5}</style>",
        f"<text x='{width/2}' y='22' text-anchor='middle' class='title'>{html.escape(title)}</text>",
    ]

    for i in range(5):
        gy = margin_top + i * plot_h / 4
        val = max_y - i * (max_y - min_y) / 4
        parts.append(f"<line x1='{margin_left}' y1='{gy}' x2='{width - margin_right}' y2='{gy}' class='grid'/>")
        parts.append(f"<text x='{margin_left - 8}' y='{gy + 4}' text-anchor='end'>{val:.1f}</text>")

    for i in range(len(sorted(set(xs)))):
        xval = sorted(set(xs))[i]
        gx = sx(xval)
        parts.append(f"<line x1='{gx}' y1='{margin_top}' x2='{gx}' y2='{height - margin_bottom}' class='grid'/>")
        parts.append(f"<text x='{gx}' y='{height - margin_bottom + 18}' text-anchor='middle'>{xval}</text>")

    parts.append(f"<line x1='{margin_left}' y1='{height - margin_bottom}' x2='{width - margin_right}' y2='{height - margin_bottom}' class='axis'/>")
    parts.append(f"<line x1='{margin_left}' y1='{margin_top}' x2='{margin_left}' y2='{height - margin_bottom}' class='axis'/>")
    parts.append(f"<text x='{width/2}' y='{height - 10}' text-anchor='middle'>ctx_size</text>")
    parts.append(f"<text x='18' y='{height/2}' text-anchor='middle' transform='rotate(-90 18 {height/2})'>{html.escape(y_label)}</text>")

    legend_x = width - 180
    legend_y = 38
    for idx, (label, pts) in enumerate(series_map.items()):
        color = colors[idx % len(colors)]
        point_str = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y, _meta in pts)
        parts.append(f"<polyline fill='none' stroke='{color}' stroke-width='2.5' points='{point_str}'/>")
        for x, y, meta in pts:
            parts.append(
                f"<circle class='pt' cx='{sx(x):.1f}' cy='{sy(y):.1f}' r='4' fill='{color}'>"
                f"<title>{html.escape(meta)}</title></circle>"
            )
        ly = legend_y + idx * 18
        parts.append(f"<line x1='{legend_x}' y1='{ly}' x2='{legend_x + 18}' y2='{ly}' stroke='{color}' stroke-width='3'/>")
        parts.append(f"<text x='{legend_x + 24}' y='{ly + 4}'>{html.escape(label)}</text>")

    parts.append("</svg>")
    return "\n".join(parts)


def build_series(label, rows_by_ctx, metric):
    pts = []
    for ctx, row in rows_by_ctx.items():
        meta = (
            f"{label}: ctx={ctx}, batch={row['batch_size']}, ubatch={row['ubatch_size']}, "
            f"{metric}={row[metric]:.2f}, rss={row['avg_rss_mb']:.1f} MiB"
        )
        pts.append((ctx, row[metric], meta))
    return pts


def write_markdown(out_path, left_label, right_label, left_best_speed, right_best_speed, left_best_mem, right_best_mem, svg_speed_path, svg_mem_path):
    lines = [
        f"# Tuning Graph Comparison: {left_label} vs {right_label}",
        "",
        "## Best Completion tok/s By ctx_size",
        "",
        f"![Completion tok/s]({svg_speed_path.name})",
        "",
        "## Lowest RSS By ctx_size",
        "",
        f"![Lowest RSS]({svg_mem_path.name})",
        "",
        "## Best-speed Rows",
        "",
        f"| label | ctx | batch | ubatch | completion tok/s | total tok/s | avg RSS MiB |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for label, rows in [(left_label, left_best_speed), (right_label, right_best_speed)]:
        for ctx, row in rows.items():
            lines.append(
                f"| {label} | {ctx} | {row['batch_size']} | {row['ubatch_size']} | "
                f"{row['avg_completion_tok_s']:.2f} | {row['avg_total_tok_s']:.2f} | {row['avg_rss_mb']:.1f} |"
            )
    lines.extend([
        "",
        "## Lowest-memory Rows",
        "",
        f"| label | ctx | batch | ubatch | avg RSS MiB | peak RSS MiB | completion tok/s |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ])
    for label, rows in [(left_label, left_best_mem), (right_label, right_best_mem)]:
        for ctx, row in rows.items():
            lines.append(
                f"| {label} | {ctx} | {row['batch_size']} | {row['ubatch_size']} | "
                f"{row['avg_rss_mb']:.1f} | {row['peak_rss_mb']:.1f} | {row['avg_completion_tok_s']:.2f} |"
            )
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--left", required=True)
    ap.add_argument("--right", required=True)
    ap.add_argument("--left-label", default="left")
    ap.add_argument("--right-label", default="right")
    ap.add_argument("--output-dir", required=True)
    args = ap.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    left_rows = load_rows(args.left)
    right_rows = load_rows(args.right)

    left_best_speed = best_by_ctx(left_rows, "avg_completion_tok_s")
    right_best_speed = best_by_ctx(right_rows, "avg_completion_tok_s")
    left_best_mem = best_by_ctx(left_rows, "avg_rss_mb")
    right_best_mem = best_by_ctx(right_rows, "avg_rss_mb")

    speed_svg = out_dir / f"{args.left_label}-vs-{args.right_label}-completion.svg"
    mem_svg = out_dir / f"{args.left_label}-vs-{args.right_label}-rss.svg"
    report_md = out_dir / f"{args.left_label}-vs-{args.right_label}-graphs.md"

    speed_svg.write_text(
        svg_line_chart(
            {
                args.left_label: build_series(args.left_label, left_best_speed, "avg_completion_tok_s"),
                args.right_label: build_series(args.right_label, right_best_speed, "avg_completion_tok_s"),
            },
            f"Best Completion tok/s by ctx_size: {args.left_label} vs {args.right_label}",
            "completion tok/s",
        ),
        encoding="utf-8",
    )
    mem_svg.write_text(
        svg_line_chart(
            {
                args.left_label: build_series(args.left_label, left_best_mem, "avg_rss_mb"),
                args.right_label: build_series(args.right_label, right_best_mem, "avg_rss_mb"),
            },
            f"Lowest RSS by ctx_size: {args.left_label} vs {args.right_label}",
            "avg RSS MiB",
        ),
        encoding="utf-8",
    )
    write_markdown(report_md, args.left_label, args.right_label, left_best_speed, right_best_speed, left_best_mem, right_best_mem, speed_svg, mem_svg)
    print(report_md)


if __name__ == "__main__":
    main()
