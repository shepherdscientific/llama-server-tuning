#!/usr/bin/env bash
set -euo pipefail

server_bin="/Users/yoda/tools/llama-cpp-turboquant/build/bin/llama-server"
model_path="${HOME}/Models/keep/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M.gguf"
port=8080
label="qwen-tune"
ctx_sizes="32768 65536 98304 131072 163840 196608"
batch_sizes="512 1024 2048"
ubatch_sizes="128 256 512"
cache_type_k="f16"
cache_type_v="f16"
gpu_layers=99
flash_attn=1
parallel=1
cache_ram=0
mode="prompt"
prompt_repeats=1200
ctx_fill_ratio=""
approx_tokens_per_repeat=14.12
max_tokens=512
runs=3
warmups=1
health_attempts=30
output_root="${PWD}/tuning-results"
output_dir=""
extra_server_args=""

usage() {
  cat <<'EOF'
Usage: tune_qwen_server.sh [options]

Sweeps llama-server settings one configuration at a time, health-checks each run,
and benchmarks stable configs using benchmark_qwen.sh in single-endpoint mode.

Options:
  --server-bin PATH         Path to llama-server binary
  --model-path PATH         Path to GGUF model
  --port PORT               Port to use during tuning (default: 8080)
  --label NAME              Label prefix for outputs (default: qwen-tune)
  --ctx-sizes "LIST"        Space-separated ctx sizes (default: "32768 65536 98304 131072 163840 196608")
  --batch-sizes "LIST"      Space-separated batch sizes (default: "512 1024")
  --ubatch-sizes "LIST"     Space-separated ubatch sizes (default: "128 256 512")
  --cache-type-k TYPE       KV cache type for K (default: f16)
  --cache-type-v TYPE       KV cache type for V (default: f16)
  --gpu-layers N            GPU layers (default: 99)
  --parallel N              Parallel slots (default: 1)
  --cache-ram N             Prompt cache RAM MiB (default: 0)
  --mode MODE               Benchmark mode: prompt or decode (default: prompt)
  --prompt-repeats N        Fixed prompt repeat count for prompt mode (default: 1200)
  --ctx-fill-ratio FLOAT    Derive prompt size from ctx size, e.g. 0.80 for ~80% occupancy
  --approx-tokens-per-repeat FLOAT
                            Prompt token estimate per repeat when using --ctx-fill-ratio (default: 14.12)
  --max-tokens N            Completion tokens for benchmark (default: 512)
  --runs N                  Measured runs per config (default: 3)
  --warmups N               Warmup runs per config (default: 1)
  --output-dir DIR          Root directory for logs/results (a timestamped run dir is created inside it)
  --extra-server-args STR   Extra server args appended verbatim
  -h, --help                Show this help

Example:
  tune_qwen_server.sh \
    --cache-type-k turbo3 \
    --cache-type-v turbo3 \
    --ctx-sizes "32768 65536 131072" \
    --batch-sizes "512 1024 2048" \
    --ubatch-sizes "128 256 512" \
    --ctx-fill-ratio 0.80
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-bin)
      server_bin=$2
      shift 2
      ;;
    --model-path)
      model_path=$2
      shift 2
      ;;
    --port)
      port=$2
      shift 2
      ;;
    --label)
      label=$2
      shift 2
      ;;
    --ctx-sizes)
      ctx_sizes=$2
      shift 2
      ;;
    --batch-sizes)
      batch_sizes=$2
      shift 2
      ;;
    --ubatch-sizes)
      ubatch_sizes=$2
      shift 2
      ;;
    --cache-type-k)
      cache_type_k=$2
      shift 2
      ;;
    --cache-type-v)
      cache_type_v=$2
      shift 2
      ;;
    --gpu-layers)
      gpu_layers=$2
      shift 2
      ;;
    --parallel)
      parallel=$2
      shift 2
      ;;
    --cache-ram)
      cache_ram=$2
      shift 2
      ;;
    --mode)
      mode=$2
      shift 2
      ;;
    --prompt-repeats)
      prompt_repeats=$2
      shift 2
      ;;
    --ctx-fill-ratio)
      ctx_fill_ratio=$2
      shift 2
      ;;
    --approx-tokens-per-repeat)
      approx_tokens_per_repeat=$2
      shift 2
      ;;
    --max-tokens)
      max_tokens=$2
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
    --output-dir)
      output_root=$2
      shift 2
      ;;
    --extra-server-args)
      extra_server_args=$2
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

timestamp=$(date +"%Y%m%d-%H%M%S")
output_dir="${output_root}/${label}-${timestamp}"
mkdir -p "$output_dir"

summary_tsv="${output_dir}/${label}-summary.tsv"
summary_md="${output_dir}/${label}-summary.md"

printf "label\tctx_size\tbatch_size\tubatch_size\tstatus\tavg_completion_tok_s\tavg_total_tok_s\tavg_wall_s\tavg_rss_mb\tpeak_rss_mb\tserver_log\tbenchmark_log\n" > "$summary_tsv"

find_pid() {
  lsof -tiTCP:"$port" -sTCP:LISTEN -n -P | head -1 || true
}

stop_server() {
  local pid
  pid=$(find_pid)
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    for ((i = 1; i <= 20; i++)); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

health_check() {
  local payload
  payload='{"model":"qwen3-coder-next","messages":[{"role":"user","content":"Say hello"}],"temperature":0,"max_tokens":32}'
  for ((i = 1; i <= health_attempts; i++)); do
    response=$(curl -s "http://127.0.0.1:${port}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "$payload" || true)
    if echo "$response" | rg -q '"choices"'; then
      return 0
    fi
    if echo "$response" | rg -q '"Compute error"'; then
      sleep 1
    else
      sleep 2
    fi
  done
  return 1
}

parse_summary() {
  local benchmark_log=$1
  python3 - "$benchmark_log" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
m = re.search(
    r"avg completion tok/s=([0-9.]+), avg total tok/s=([0-9.]+), avg wall=([0-9.]+)s, avg RSS=([0-9.]+) MiB, peak RSS=([0-9.]+) MiB",
    text,
)
if not m:
    print("\t".join(["NA"] * 5))
else:
    print("\t".join(m.groups()))
PY
}

write_markdown_summary() {
  python3 - "$summary_tsv" "$summary_md" <<'PY'
import csv
import pathlib
import sys

tsv_path = pathlib.Path(sys.argv[1])
md_path = pathlib.Path(sys.argv[2])

rows = []
with tsv_path.open("r", encoding="utf-8") as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        rows.append(row)

ok_rows = [r for r in rows if r["status"] == "ok"]

def as_float(row, key):
    try:
        return float(row[key])
    except Exception:
        return float("inf")

lines = []
lines.append("# Qwen Server Tuning Results")
lines.append("")
lines.append(f"- Total configs tried: {len(rows)}")
lines.append(f"- Healthy configs: {len(ok_rows)}")
lines.append(f"- Failed configs: {len(rows) - len(ok_rows)}")
lines.append("")

if ok_rows:
    fastest = sorted(ok_rows, key=lambda r: as_float(r, "avg_completion_tok_s"), reverse=True)[:5]
    lowest_mem = sorted(ok_rows, key=lambda r: as_float(r, "avg_rss_mb"))[:5]

    lines.append("## Top 5 By Completion tok/s")
    lines.append("")
    lines.append("| ctx | batch | ubatch | completion tok/s | total tok/s | wall s | avg RSS MiB | peak RSS MiB |")
    lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in fastest:
        lines.append(
            f"| {r['ctx_size']} | {r['batch_size']} | {r['ubatch_size']} | "
            f"{r['avg_completion_tok_s']} | {r['avg_total_tok_s']} | {r['avg_wall_s']} | "
            f"{r['avg_rss_mb']} | {r['peak_rss_mb']} |"
        )
    lines.append("")

    lines.append("## Top 5 By Lowest RSS")
    lines.append("")
    lines.append("| ctx | batch | ubatch | completion tok/s | total tok/s | wall s | avg RSS MiB | peak RSS MiB |")
    lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in lowest_mem:
        lines.append(
            f"| {r['ctx_size']} | {r['batch_size']} | {r['ubatch_size']} | "
            f"{r['avg_completion_tok_s']} | {r['avg_total_tok_s']} | {r['avg_wall_s']} | "
            f"{r['avg_rss_mb']} | {r['peak_rss_mb']} |"
        )
    lines.append("")

lines.append("## All Configs")
lines.append("")
lines.append("| status | ctx | batch | ubatch | completion tok/s | total tok/s | wall s | avg RSS MiB | peak RSS MiB | benchmark log |")
lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---|")
for r in rows:
    bench = pathlib.Path(r["benchmark_log"]).name if r["benchmark_log"] else ""
    lines.append(
        f"| {r['status']} | {r['ctx_size']} | {r['batch_size']} | {r['ubatch_size']} | "
        f"{r['avg_completion_tok_s']} | {r['avg_total_tok_s']} | {r['avg_wall_s']} | "
        f"{r['avg_rss_mb']} | {r['peak_rss_mb']} | {bench} |"
    )

md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

run_config() {
  local ctx_size=$1
  local batch_size=$2
  local ubatch_size=$3
  local effective_prompt_repeats=$prompt_repeats
  local cfg_name="${label}-ctx${ctx_size}-b${batch_size}-ub${ubatch_size}"
  local server_log="${output_dir}/${cfg_name}.server.log"
  local benchmark_log="${output_dir}/${cfg_name}.benchmark.log"
  local pid
  local parsed

  if [[ -n "$ctx_fill_ratio" && "$mode" == "prompt" ]]; then
    effective_prompt_repeats=$(python3 - "$ctx_size" "$ctx_fill_ratio" "$approx_tokens_per_repeat" <<'PY'
import math
import sys
ctx = float(sys.argv[1])
ratio = float(sys.argv[2])
tokens_per_repeat = float(sys.argv[3])
repeats = max(1, int(math.floor((ctx * ratio) / tokens_per_repeat)))
print(repeats)
PY
)
  fi

  stop_server

  echo "Starting ${cfg_name} (prompt_repeats=${effective_prompt_repeats})"
  "${server_bin}" \
    --host 0.0.0.0 \
    -m "${model_path}" \
    --port "${port}" \
    --jinja \
    --ctx-size "${ctx_size}" \
    --n-gpu-layers "${gpu_layers}" \
    --flash-attn "${flash_attn}" \
    --cache-type-k "${cache_type_k}" \
    --cache-type-v "${cache_type_v}" \
    --batch-size "${batch_size}" \
    --ubatch-size "${ubatch_size}" \
    --parallel "${parallel}" \
    --cache-ram "${cache_ram}" \
    --cont-batching \
    --alias qwen3-coder-next \
    --log-disable \
    --verbosity 0 \
    ${extra_server_args} > "${server_log}" 2>&1 &

  launcher_pid=$!

  if ! health_check; then
    echo "Health check failed for ${cfg_name}" | tee "${benchmark_log}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "${label}" "${ctx_size}" "${batch_size}" "${ubatch_size}" "health_failed" \
      "NA" "NA" "NA" "NA" "NA" "${server_log}" "${benchmark_log}" >> "${summary_tsv}"
    kill "${launcher_pid}" 2>/dev/null || true
    wait "${launcher_pid}" 2>/dev/null || true
    stop_server
    return 1
  fi

  pid=$(find_pid)
  echo "Healthy pid=${pid}" | tee "${benchmark_log}"
  /Users/yoda/Documents/NBC/scripts/benchmark_qwen.sh \
    --single-url "http://127.0.0.1:${port}/v1/chat/completions" \
    --single-pid "${pid}" \
    --single-label "${label}" \
    --runs "${runs}" \
    --warmups "${warmups}" \
    --max-tokens "${max_tokens}" \
    --mode "${mode}" \
    --prompt-repeats "${effective_prompt_repeats}" | tee -a "${benchmark_log}"

  parsed=$(parse_summary "${benchmark_log}")
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${label}" "${ctx_size}" "${batch_size}" "${ubatch_size}" "ok" \
    ${parsed} "${server_log}" "${benchmark_log}" >> "${summary_tsv}"

  stop_server
}

cleanup() {
  stop_server
}
trap cleanup EXIT

for ctx_size in ${ctx_sizes}; do
  for batch_size in ${batch_sizes}; do
    for ubatch_size in ${ubatch_sizes}; do
      echo
      echo "=== ctx=${ctx_size} batch=${batch_size} ubatch=${ubatch_size} ==="
      run_config "${ctx_size}" "${batch_size}" "${ubatch_size}"
    done
  done
done

write_markdown_summary

echo
echo "Run directory: ${output_dir}"
echo "TSV summary: ${summary_tsv}"
echo "Markdown summary: ${summary_md}"
