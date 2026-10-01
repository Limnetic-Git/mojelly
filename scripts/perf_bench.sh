#!/bin/bash
# Load-test a built Mojelly server with oha and write the result as JSON.
#
# Usage: scripts/perf_bench.sh <dir-with-built-server> <result.json>
#
# Env (all optional):
#   PERF_PATH         endpoint to hit              (default /json)
#   PERF_DURATION     measured run, seconds        (default 30)
#   PERF_WARMUP       warmup run, seconds          (default 5)
#   PERF_CONNECTIONS  concurrent connections       (default 100)
#   PERF_SERVER_CPUS  taskset cpu list for server  (default: unpinned)
#   PERF_CLIENT_CPUS  taskset cpu list for oha     (default: unpinned)
#   PERF_PORT         server port                  (default 8080)
set -euo pipefail

DIR="${1:?usage: perf_bench.sh <server-dir> <result.json>}"
OUT="${2:?usage: perf_bench.sh <server-dir> <result.json>}"

OUT="$(realpath -m "$OUT")"  # resolve before cd below

PATH_="${PERF_PATH:-/json}"
DURATION="${PERF_DURATION:-30}"
WARMUP="${PERF_WARMUP:-5}"
CONNS="${PERF_CONNECTIONS:-100}"
PORT="${PERF_PORT:-8080}"

pin() { # pin <cpus> <cmd...>
    local cpus="$1"; shift
    if [ -n "$cpus" ]; then taskset -c "$cpus" "$@"; else "$@"; fi
}

cd "$DIR"
pin "${PERF_SERVER_CPUS:-}" ./server > server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
    if curl -fs "http://localhost:$PORT/" > /dev/null; then break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "server died:"; cat server.log; exit 1; }
    sleep 0.2
done

URL="http://localhost:$PORT$PATH_"
pin "${PERF_CLIENT_CPUS:-}" oha -z "${WARMUP}s" -c "$CONNS" --no-tui "$URL" > /dev/null 2>&1
pin "${PERF_CLIENT_CPUS:-}" oha -z "${DURATION}s" -c "$CONNS" --no-tui \
    --output-format json "$URL" > oha.json

jq '{rps: .summary.requestsPerSec,
     p99_ms: (.latencyPercentiles.p99 * 1000),
     success_rate: .summary.successRate}' oha.json > "$OUT"
cat "$OUT"
