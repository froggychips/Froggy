#!/usr/bin/env bash
# Запускает один цикл /froggy-bench для текущего сценария и пишет результат
# в bench/baseline.json (схема в bench/baseline.template.json).
#
# Сценарий определяется автоматически:
#   * нет worker'а                                 → "idle"
#   * worker запущен, modelLoaded=true, нет давления → "model-loaded"
#   * pressureLevel = warning|critical              → "under-pressure"
#
# Usage: bench/run.sh [--save]
#   --save  — добавить snapshot к bench/baseline.json (создать если нет).
#             Без флага — просто вывести JSON в stdout.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="$HOME/Library/Application Support/Froggy/froggy.sock"
FROGGY_BIN="$ROOT/.build/release/froggy"
[ -x "$FROGGY_BIN" ] || FROGGY_BIN="$ROOT/.build/arm64-apple-macosx/release/froggy"

SAVE=0
[ "${1:-}" = "--save" ] && SAVE=1

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Системные счётчики
vm_stat_raw="$(vm_stat)"
mp_raw="$(memory_pressure 2>/dev/null || echo n/a)"

# 2. Pids/RSS
daemon_pid="$(pgrep FroggyDaemon | head -1 || true)"
worker_pid="$(pgrep FroggyMLXWorker | head -1 || true)"
daemon_rss="$( [ -n "$daemon_pid" ] && ps -o rss= -p "$daemon_pid" | tr -d ' ' || echo null)"
worker_rss="$( [ -n "$worker_pid" ] && ps -o rss= -p "$worker_pid" | tr -d ' ' || echo null)"

# 3. Froggy status / pressure (через CLI; если daemon не запущен — null)
froggy_status_raw="$($FROGGY_BIN status 2>/dev/null || true)"
froggy_pressure_raw="$(echo '{"cmd":"pressure"}' | nc -U "$SOCK" 2>/dev/null || true)"

# 4. Сценарий
scenario="idle"
case "$froggy_pressure_raw" in
  *'"pressureLevel":"critical"'*) scenario="under-pressure";;
  *'"pressureLevel":"warning"'*)  scenario="under-pressure";;
esac
case "$froggy_status_raw" in
  *modelLoaded*yes*) [ "$scenario" = "idle" ] && scenario="model-loaded";;
esac

# 5. Time-to-first-token (если модель загружена)
ttft_ms=null
if [ "$scenario" = "model-loaded" ]; then
  start=$(python3 -c 'import time; print(int(time.time()*1000))')
  echo '{"cmd":"generate","prompt":"hi","maxTokens":1}' | nc -U "$SOCK" 2>/dev/null | head -1 >/dev/null
  end=$(python3 -c 'import time; print(int(time.time()*1000))')
  ttft_ms=$((end - start))
fi

# 6. Compose JSON snapshot
snapshot=$(cat <<JSON
{
  "schema_version": 1,
  "captured_at": "$ts",
  "scenario": "$scenario",
  "daemon_rss_kb": $daemon_rss,
  "worker_rss_kb": $worker_rss,
  "ttft_ms": $ttft_ms,
  "vm_stat_raw": $(printf '%s' "$vm_stat_raw" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "memory_pressure_raw": $(printf '%s' "$mp_raw" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "froggy_status": $(printf '%s' "${froggy_status_raw:-null}" | python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(json.dumps(s) if s else "null")'),
  "froggy_pressure": $(printf '%s' "${froggy_pressure_raw:-null}" | python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(json.dumps(s) if s else "null")')
}
JSON
)

if [ "$SAVE" = "1" ]; then
  out="$ROOT/bench/baseline.json"
  if [ ! -s "$out" ]; then
    echo "[$snapshot]" > "$out"
  else
    # Append snapshot в массив
    python3 - "$out" "$snapshot" <<'PY'
import json, sys
path, snap = sys.argv[1], sys.argv[2]
with open(path) as f: arr = json.load(f)
arr.append(json.loads(snap))
with open(path, 'w') as f: json.dump(arr, f, indent=2, ensure_ascii=False)
PY
  fi
  echo "saved $scenario to $out"
else
  echo "$snapshot"
fi
