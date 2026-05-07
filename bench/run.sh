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

# 2. Pids/RSS — distribution из 10 сэмплов с интервалом 1s.
# Single-sample обманчив: под pressure'ом RSS живёт sawtooth'ом 50-150 MB
# (Vision IOSurface буферы периодически evict'ятся kernel'ом). Нужен min/median/max.
daemon_pid="$(pgrep FroggyDaemon | head -1 || true)"
worker_pid="$(pgrep FroggyMLXWorker | head -1 || true)"

sample_rss() {
  local pid="$1"
  [ -z "$pid" ] && { echo "null,null,null,null,[]"; return; }
  python3 - "$pid" <<'PY'
import subprocess, sys, time, json
pid = sys.argv[1]
samples = []
for _ in range(10):
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", pid], text=True).strip()
        if out:
            samples.append(int(out))
    except subprocess.CalledProcessError:
        break
    time.sleep(1)
if not samples:
    print("null,null,null,null,[]")
else:
    s = sorted(samples)
    median = s[len(s)//2]
    print(f"{min(s)},{median},{max(s)},{int(sum(s)/len(s))},{json.dumps(samples)}")
PY
}

IFS=',' read -r daemon_rss_min daemon_rss_median daemon_rss_max daemon_rss_mean daemon_rss_samples < <(sample_rss "$daemon_pid")
IFS=',' read -r worker_rss_min worker_rss_median worker_rss_max worker_rss_mean worker_rss_samples < <(sample_rss "$worker_pid")
# Backward compat: daemon_rss_kb = median.
daemon_rss="$daemon_rss_median"
worker_rss="$worker_rss_median"

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
  *"model_loaded     yes"*) [ "$scenario" = "idle" ] && scenario="model-loaded";;
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
  "schema_version": 2,
  "captured_at": "$ts",
  "scenario": "$scenario",
  "daemon_rss_kb": $daemon_rss,
  "daemon_rss_kb_distribution": {
    "min": $daemon_rss_min,
    "median": $daemon_rss_median,
    "max": $daemon_rss_max,
    "mean": $daemon_rss_mean,
    "samples": $daemon_rss_samples
  },
  "worker_rss_kb": $worker_rss,
  "worker_rss_kb_distribution": {
    "min": $worker_rss_min,
    "median": $worker_rss_median,
    "max": $worker_rss_max,
    "mean": $worker_rss_mean,
    "samples": $worker_rss_samples
  },
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
