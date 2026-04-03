#!/usr/bin/env bash
set -euo pipefail

turbo_launcher="${HOME}/.local/bin/test-qwen3-coder-turbo.sh"
f16_launcher="${HOME}/.local/bin/test-qwen3-coder-next.sh"
turbo_port=8080
f16_port=8081
runs=5
warmups=1
max_tokens=512
mode="prompt"
output_dir="${PWD}/benchmark-results"
prompt_repeats_list="400 1200 2400 3600"

usage() {
  cat <<'EOF'
Usage: benchmark_qwen_stepwise.sh [options]

Runs stepped one-at-a-time benchmarks for turbo and f16 launcher scripts.

Options:
  --turbo-launcher PATH   Launcher script for turbo config
  --f16-launcher PATH     Launcher script for f16 config
  --turbo-port PORT       Port used by turbo launcher (default: 8080)
  --f16-port PORT         Port used by f16 launcher (default: 8081)
  --runs N                Measured runs per step (default: 5)
  --warmups N             Warmup runs per step (default: 1)
  --max-tokens N          Max completion tokens (default: 512)
  --mode MODE             decode or prompt (default: prompt)
  --prompt-repeats LIST   Quoted space-separated repeat counts (default: "400 1200 2400 3600")
  --output-dir DIR        Directory for benchmark logs/results
  -h, --help              Show this help

Example:
  benchmark_qwen_stepwise.sh --prompt-repeats "400 1200 2400 3600 4800"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --turbo-launcher)
      turbo_launcher=$2
      shift 2
      ;;
    --f16-launcher)
      f16_launcher=$2
      shift 2
      ;;
    --turbo-port)
      turbo_port=$2
      shift 2
      ;;
    --f16-port)
      f16_port=$2
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
    --prompt-repeats)
      prompt_repeats_list=$2
      shift 2
      ;;
    --output-dir)
      output_dir=$2
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

mkdir -p "$output_dir"

health_check() {
  local port=$1
  local attempts=30
  local body='{"model":"qwen3-coder-next","messages":[{"role":"user","content":"Say hello"}],"temperature":0,"max_tokens":32}'

  for ((i = 1; i <= attempts; i++)); do
    response=$(curl -s "http://127.0.0.1:${port}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "$body" || true)
    if echo "$response" | rg -q '"choices"'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

find_pid() {
  local port=$1
  lsof -tiTCP:"$port" -sTCP:LISTEN -n -P | head -1
}

stop_port() {
  local port=$1
  local pid
  pid=$(find_pid "$port" || true)
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

run_config() {
  local label=$1
  local launcher=$2
  local port=$3
  local repeats=$4
  local logfile="${output_dir}/${label}-r${repeats}.server.log"
  local outfile="${output_dir}/${label}-r${repeats}.benchmark.txt"
  local pid

  stop_port "$port"
  echo "Starting ${label} on port ${port} with repeats=${repeats}"
  "$launcher" >"$logfile" 2>&1 &
  launcher_pid=$!

  if ! health_check "$port"; then
    echo "${label} failed health check for repeats=${repeats}. See ${logfile}" | tee "$outfile"
    kill "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
    return 1
  fi

  pid=$(find_pid "$port")
  echo "Healthy ${label} pid=${pid} port=${port}" | tee "$outfile"
  /Users/yoda/Documents/NBC/scripts/benchmark_qwen.sh \
    --single-url "http://127.0.0.1:${port}/v1/chat/completions" \
    --single-pid "$pid" \
    --single-label "$label" \
    --runs "$runs" \
    --warmups "$warmups" \
    --max-tokens "$max_tokens" \
    --mode "$mode" \
    --prompt-repeats "$repeats" | tee -a "$outfile"

  stop_port "$port"
}

for repeats in $prompt_repeats_list; do
  echo
  echo "=== repeats=${repeats} ==="
  run_config turbo "$turbo_launcher" "$turbo_port" "$repeats"
  run_config f16 "$f16_launcher" "$f16_port" "$repeats"
done

echo
echo "Saved results in: $output_dir"
