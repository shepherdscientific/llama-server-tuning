#!/usr/bin/env bash
set -euo pipefail

plain_url="http://127.0.0.1:8080/v1/chat/completions"
turbo_url="http://127.0.0.1:8081/v1/chat/completions"
plain_pid=""
turbo_pid=""
single_url=""
single_pid=""
single_label="single"
runs=3
warmups=1
max_tokens=512
mode="decode"
model="qwen3-coder-next"
prompt_repeats=400

usage() {
  cat <<'EOF'
Usage: benchmark_qwen.sh [options]

Options:
  --plain-url URL     Non-turbo server endpoint
  --turbo-url URL     Turbo server endpoint
  --runs N            Measured runs per server (default: 3)
  --warmups N         Warmup runs per server (default: 1)
  --max-tokens N      Completion tokens requested (default: 512)
  --mode MODE         "decode" or "prompt" (default: decode)
  --model NAME        Model name to send in the request
  --plain-pid PID     PID of the non-turbo server for RSS sampling
  --turbo-pid PID     PID of the turbo server for RSS sampling
  --single-url URL    Benchmark a single endpoint only
  --single-pid PID    PID for the single endpoint mode
  --single-label TXT  Label to use in single endpoint mode (default: single)
  --prompt-repeats N  Number of repeated chunks in prompt mode (default: 400)
  -h, --help          Show this help

Examples:
  benchmark_qwen.sh
  benchmark_qwen.sh --plain-url http://127.0.0.1:8080/v1/chat/completions \
    --turbo-url http://127.0.0.1:8081/v1/chat/completions --runs 5 --mode prompt
  benchmark_qwen.sh --plain-pid 12345 --turbo-pid 23456
  benchmark_qwen.sh --single-url http://127.0.0.1:8080/v1/chat/completions \
    --single-pid 12345 --single-label turbo --mode prompt --prompt-repeats 2400
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plain-url)
      plain_url=$2
      shift 2
      ;;
    --turbo-url)
      turbo_url=$2
      shift 2
      ;;
    --runs)
      runs=$2
      shift 2
      ;;
    --warmups)
      warmups=$2
      shift 2
      ;;
    --max-tokens)
      max_tokens=$2
      shift 2
      ;;
    --mode)
      mode=$2
      shift 2
      ;;
    --model)
      model=$2
      shift 2
      ;;
    --plain-pid)
      plain_pid=$2
      shift 2
      ;;
    --turbo-pid)
      turbo_pid=$2
      shift 2
      ;;
    --single-url)
      single_url=$2
      shift 2
      ;;
    --single-pid)
      single_pid=$2
      shift 2
      ;;
    --single-label)
      single_label=$2
      shift 2
      ;;
    --prompt-repeats)
      prompt_repeats=$2
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

if [[ "$mode" != "decode" && "$mode" != "prompt" ]]; then
  echo "--mode must be decode or prompt" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

build_prompt() {
  local prompt_mode=$1
  local chunk repeat_count body

  if [[ "$prompt_mode" == "decode" ]]; then
    cat <<'EOF'
You are benchmarking local inference.
Write a detailed but compact explanation of how to implement a file watcher in Python that:
- debounces repeated file changes
- handles symlink loops safely
- falls back to polling when native events fail
- exposes a clean callback interface

Include pseudocode and key tradeoffs.
EOF
  else
    chunk="The quick brown fox benchmarks long-context prompt ingestion for Qwen coder. "
    repeat_count=$prompt_repeats
    body=""
    for ((i = 0; i < repeat_count; i++)); do
      body+="$chunk"
    done
    printf '%s\n%s\n' \
      "$body" \
      "Summarize the design considerations in 12 bullet points."
  fi
}

run_one() {
  local label=$1
  local url=$2
  local pass_type=$3
  local run_id=$4
  local prompt_file=$5
  local pid=$6
  local response_file metrics_file body_file mem_file sampler_pid=""

  response_file="$tmpdir/${label}_${pass_type}_${run_id}.json"
  metrics_file="$tmpdir/${label}_${pass_type}_${run_id}.metrics"
  body_file="$tmpdir/${label}_${pass_type}_${run_id}.request.json"
  mem_file="$tmpdir/${label}_${pass_type}_${run_id}.mem.tsv"

  python3 - "$model" "$max_tokens" "$prompt_file" "$body_file" "$run_id" "$pass_type" <<'PY'
import json
import sys
model, max_tokens, prompt_file, body_file, run_id, pass_type = sys.argv[1:]
with open(prompt_file, "r", encoding="utf-8") as f:
    prompt = f.read()
messages = [
    {"role": "system", "content": "You are a coding assistant. Respond directly."},
    {
        "role": "user",
        "content": prompt + f"\n\nBenchmark nonce: run={run_id}; phase={pass_type};",
    },
]
body = {
    "model": model,
    "messages": messages,
    "temperature": 0,
    "top_p": 1,
    "max_tokens": int(max_tokens),
}
with open(body_file, "w", encoding="utf-8") as f:
    json.dump(body, f)
PY

  if [[ -n "$pid" ]]; then
    sample_memory "$pid" "$mem_file" &
    sampler_pid=$!
  fi

  curl -sS -o "$response_file" \
    -w 'http_code=%{http_code}\ntime_total=%{time_total}\nsize_download=%{size_download}\n' \
    -H 'Content-Type: application/json' \
    --data @"$body_file" \
    "$url" > "$metrics_file"

  if [[ -n "$sampler_pid" ]]; then
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
  fi

  python3 - "$label" "$pass_type" "$run_id" "$response_file" "$metrics_file" "$mem_file" <<'PY'
import json
import pathlib
import sys

label, pass_type, run_id, response_path, metrics_path, mem_path = sys.argv[1:]

metrics = {}
for line in pathlib.Path(metrics_path).read_text().splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        metrics[k] = v

http_code = int(metrics.get("http_code", "0"))
time_total = float(metrics.get("time_total", "0"))

response = {}
try:
    response = json.loads(pathlib.Path(response_path).read_text())
except Exception:
    pass

usage = response.get("usage", {})
prompt_tokens = int(usage.get("prompt_tokens", 0) or 0)
completion_tokens = int(usage.get("completion_tokens", 0) or 0)
total_tokens = int(usage.get("total_tokens", prompt_tokens + completion_tokens) or 0)

if time_total > 0:
    completion_tps = completion_tokens / time_total
    total_tps = total_tokens / time_total
else:
    completion_tps = 0.0
    total_tps = 0.0

rss_samples = []
mem_path_obj = pathlib.Path(mem_path)
if mem_path_obj.exists():
    for line in mem_path_obj.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        try:
            rss_samples.append(int(parts[1]))
        except ValueError:
            pass

rss_avg_mb = (sum(rss_samples) / len(rss_samples) / 1024.0) if rss_samples else 0.0
rss_peak_mb = (max(rss_samples) / 1024.0) if rss_samples else 0.0

print(
    f"{label}\t{pass_type}\t{run_id}\t{http_code}\t"
    f"{prompt_tokens}\t{completion_tokens}\t{total_tokens}\t"
    f"{time_total:.3f}\t{completion_tps:.2f}\t{total_tps:.2f}\t"
    f"{rss_avg_mb:.1f}\t{rss_peak_mb:.1f}"
)
PY
}

sample_memory() {
  local pid=$1
  local outfile=$2
  : > "$outfile"
  while kill -0 "$pid" 2>/dev/null; do
    ps -o rss= -p "$pid" 2>/dev/null | awk -v now="$(date +%s)" '{gsub(/^ +| +$/, "", $1); if ($1 != "") print now "\t" $1}' >> "$outfile"
    sleep 0.5
  done
}

summarize() {
  local results_file=$1
  python3 - "$results_file" <<'PY'
import pathlib
import statistics
import sys

rows = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    parts = line.split("\t")
    if len(parts) != 12:
      continue
    label, pass_type, run_id, http_code, prompt_tokens, completion_tokens, total_tokens, time_total, completion_tps, total_tps, rss_avg_mb, rss_peak_mb = parts
    if pass_type != "measured" or http_code != "200":
      continue
    rows.append({
      "label": label,
      "time_total": float(time_total),
      "completion_tps": float(completion_tps),
      "total_tps": float(total_tps),
      "rss_avg_mb": float(rss_avg_mb),
      "rss_peak_mb": float(rss_peak_mb),
      "prompt_tokens": int(prompt_tokens),
      "completion_tokens": int(completion_tokens),
    })

if not rows:
  print("\nNo successful measured runs to summarize.")
  sys.exit(0)

print("\nSummary")
print("=======")
for label in sorted({r["label"] for r in rows}):
  group = [r for r in rows if r["label"] == label]
  print(
    f"{label}: "
    f"avg completion tok/s={statistics.mean(r['completion_tps'] for r in group):.2f}, "
    f"avg total tok/s={statistics.mean(r['total_tps'] for r in group):.2f}, "
    f"avg wall={statistics.mean(r['time_total'] for r in group):.3f}s, "
    f"avg RSS={statistics.mean(r['rss_avg_mb'] for r in group):.1f} MiB, "
    f"peak RSS={max(r['rss_peak_mb'] for r in group):.1f} MiB"
  )

labels = sorted({r["label"] for r in rows})
if len(labels) == 2:
  a = [r for r in rows if r["label"] == labels[0]]
  b = [r for r in rows if r["label"] == labels[1]]
  a_ctps = statistics.mean(r["completion_tps"] for r in a)
  b_ctps = statistics.mean(r["completion_tps"] for r in b)
  if a_ctps > 0:
    delta = ((b_ctps / a_ctps) - 1.0) * 100.0
    print(f"{labels[1]} vs {labels[0]} completion tok/s delta: {delta:+.2f}%")
  a_rss = statistics.mean(r["rss_avg_mb"] for r in a)
  b_rss = statistics.mean(r["rss_avg_mb"] for r in b)
  if a_rss > 0:
    delta_rss = ((b_rss / a_rss) - 1.0) * 100.0
    print(f"{labels[1]} vs {labels[0]} avg RSS delta: {delta_rss:+.2f}%")
PY
}

prompt_file="$tmpdir/prompt.txt"
build_prompt "$mode" > "$prompt_file"

results_file="$tmpdir/results.tsv"
: > "$results_file"

echo "Mode: $mode"
if [[ -n "$single_url" ]]; then
  echo "Single endpoint: $single_url"
  echo "Single PID: ${single_pid:-<not set>}"
  echo "Single label: $single_label"
else
  echo "Plain endpoint: $plain_url"
  echo "Turbo endpoint: $turbo_url"
  echo "Plain PID: ${plain_pid:-<not set>}"
  echo "Turbo PID: ${turbo_pid:-<not set>}"
fi
echo "Warmups per server: $warmups"
echo "Measured runs per server: $runs"
echo "Prompt repeats: $prompt_repeats"
echo
printf "label\tphase\trun\thttp\tprompt_tok\tcompletion_tok\ttotal_tok\twall_s\tcompletion_tok_s\ttotal_tok_s\trss_avg_mb\trss_peak_mb\n"

if [[ -n "$single_url" ]]; then
  for ((i = 1; i <= warmups; i++)); do
    run_one "$single_label" "$single_url" "warmup" "$i" "$prompt_file" "$single_pid" | tee -a "$results_file"
  done

  for ((i = 1; i <= warmups; i++)); do
    :
  done

  for ((i = 1; i <= runs; i++)); do
    run_one "$single_label" "$single_url" "measured" "$i" "$prompt_file" "$single_pid" | tee -a "$results_file"
  done
else
  for label in plain turbo; do
    if [[ "$label" == "plain" ]]; then
      url="$plain_url"
      pid="$plain_pid"
    else
      url="$turbo_url"
      pid="$turbo_pid"
    fi

    for ((i = 1; i <= warmups; i++)); do
      run_one "$label" "$url" "warmup" "$i" "$prompt_file" "$pid" | tee -a "$results_file"
    done

    for ((i = 1; i <= runs; i++)); do
      run_one "$label" "$url" "measured" "$i" "$prompt_file" "$pid" | tee -a "$results_file"
    done
  done
fi

summarize "$results_file"

cat <<'EOF'

Notes
=====
- This script compares end-to-end throughput from the client side.
- For a fair test, keep both servers on the same model and mostly identical flags.
- If prompt cache is enabled, restart the servers between benchmark sessions or keep the nonce behavior unchanged.
- Use --mode prompt to emphasize prompt ingestion, and --mode decode to emphasize generation speed.
EOF
