#!/usr/bin/env bash
# 5-cycle (по умолчанию) load/unload тест: gate-criterion из ADR 0011 —
# `worker_rss_kb=null` после unloadModel + daemon RSS не растёт после
# повторных load/unload циклов. Сейчас НЕ работает в release-сборке —
# см. ADR 0013 (default.metallib не собирается через `swift build`).
# Скрипт оставлен для использования после фикса метуллиба.
#
# Usage: bench/cycles_test.sh <model-path> [num-cycles=5]

set -uo pipefail

MODEL_PATH="${1:-$HOME/models/llama-3.2-1b-4bit}"
CYCLES="${2:-5}"
SOCK="$HOME/Library/Application Support/Froggy/froggy.sock"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_BIN="$ROOT/.build/release/FroggyDaemon"
RUN="$ROOT/bench/run.sh"

[ -x "$DAEMON_BIN" ] || { echo "ERROR: daemon binary missing at $DAEMON_BIN" >&2; exit 1; }
[ -d "$MODEL_PATH" ] || { echo "ERROR: model not found at $MODEL_PATH" >&2; exit 1; }

# Чистка предыдущих daemon/worker (если запускали)
pgrep FroggyDaemon | xargs kill -TERM 2>/dev/null
pgrep FroggyMLXWorker | xargs kill -TERM 2>/dev/null
sleep 1

echo "=== starting daemon (no model) ==="
"$DAEMON_BIN" > /tmp/froggy-cycles.log 2>&1 &
sleep 4
PID=$(pgrep FroggyDaemon)
[ -z "$PID" ] && { echo "ERROR: daemon did not start"; cat /tmp/froggy-cycles.log; exit 1; }
echo "daemon pid: $PID"

trap 'pgrep FroggyDaemon | xargs kill -TERM 2>/dev/null; pgrep FroggyMLXWorker | xargs kill -KILL 2>/dev/null' EXIT

ipc() { echo "$1" | nc -U "$SOCK" 2>/dev/null; }

echo "=== baseline (no model) ==="
"$RUN" --save | tail -1

for i in $(seq 1 "$CYCLES"); do
  echo ""
  echo "=== cycle $i: loadModel ==="
  ipc "{\"cmd\":\"loadModel\",\"path\":\"$MODEL_PATH\"}"
  for j in 1 2 3 4 5 6 7 8 9 10; do
    pgrep FroggyMLXWorker >/dev/null && { sleep 2; break; }
    sleep 1
  done
  "$RUN" --save | tail -1

  echo ""
  echo "=== cycle $i: unloadModel ==="
  ipc '{"cmd":"unloadModel"}'
  for j in 1 2 3 4 5; do
    pgrep FroggyMLXWorker >/dev/null || break
    sleep 1
  done
  pgrep FroggyMLXWorker >/dev/null && echo "WARN: worker still alive after unload (cycle $i)" >&2
  "$RUN" --save | tail -1
done

echo ""
echo "=== final ==="
ps -o rss=,pid= -p "$PID" 2>/dev/null || echo "daemon gone"
pgrep FroggyMLXWorker && echo "WARN: worker still alive at end" || echo "no worker (expected)"
