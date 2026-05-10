#!/bin/bash
# benchmark.sh — сравниваем Ollama vs Froggy: память, свап, скорость инференса
# Использование: ./scripts/benchmark.sh [ollama|froggy]
# Длительность: 60 минут. Запускать после перезагрузки, до старта рабочих приложений.
#
# Выход:
#   benchmark-metrics-SESSION-TIMESTAMP.csv  — vm_stat + давление каждые 30с
#   benchmark-prompts-SESSION-TIMESTAMP.csv  — время ответа и токены на каждый промпт
#   benchmark-summary-SESSION-TIMESTAMP.txt  — итоги сессии

set -euo pipefail

# ── Параметры ──────────────────────────────────────────────────────────────────
SESSION="${1:?Использование: ./scripts/benchmark.sh [ollama|froggy]}"
[[ "$SESSION" == "ollama" || "$SESSION" == "froggy" ]] || {
    echo "SESSION должен быть 'ollama' или 'froggy'" >&2; exit 1
}

DURATION_SEC=3600       # 60 минут
METRICS_INTERVAL=30     # снимаем vm_stat каждые 30с
PROMPT_INTERVAL=300     # промпт каждые 5 минут

OLLAMA_MODEL="qwen2.5:3b"
FROGGY_MODEL="qwen3-4b-4bit"      # информационно, для summary
FROGGY_SOCKET="$HOME/Library/Application Support/Froggy/froggy.sock"
MAX_TOKENS=200

TS=$(date +%Y%m%d-%H%M%S)
OUT_DIR="$(dirname "$0")/../benchmark-results"
mkdir -p "$OUT_DIR"
METRICS_CSV="$OUT_DIR/benchmark-metrics-${SESSION}-${TS}.csv"
PROMPTS_CSV="$OUT_DIR/benchmark-prompts-${SESSION}-${TS}.csv"
SUMMARY_TXT="$OUT_DIR/benchmark-summary-${SESSION}-${TS}.txt"

# ── Промпты ────────────────────────────────────────────────────────────────────
# Одинаковые для обеих сессий. Короткие (быстрый ответ) + средние (reasoning).
PROMPTS=(
    "What is the capital of France? Answer in one sentence."
    "Write a Swift function that reverses a string without using built-in reverse methods."
    "Explain memory pressure in macOS in 3 sentences, focusing on unified memory."
    "What is the difference between SIGSTOP and SIGKILL in Unix?"
    "Write a bash one-liner to find the 5 largest files in the current directory."
    "Explain what a KV-cache is in LLM inference in simple terms."
    "Write a Python function to calculate Fibonacci up to n terms."
    "What is the difference between active and inactive memory pages in macOS vm_stat output?"
    "Describe two advantages of running MLX models on Apple Silicon vs CUDA."
    "Write a SQL query to find duplicate email addresses in a users table."
    "What does SIGSTOP + forced pageout achieve that SIGKILL does not?"
    "What is unified memory and why does it matter for running LLMs on a MacBook?"
)
PROMPT_COUNT=${#PROMPTS[@]}

# ── Хелперы ────────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }

ms_now() { python3 -c "import time; print(int(time.time()*1000))"; }

parse_vm_stat_page() {
    # Парсим строку vm_stat, убираем точки (разделитель тысяч), возвращаем число
    echo "$1" | grep "$2" | awk '{print $NF}' | tr -d '.'
}

get_pressure_level() {
    memory_pressure 2>/dev/null | grep -Eo 'System-wide memory free percentage: [0-9]+' \
        | awk '{print $NF}' || echo "?"
}

get_swap_counts() {
    local mp
    mp=$(memory_pressure 2>/dev/null)
    local ins outs
    ins=$(echo "$mp" | grep "^Swapins:" | awk '{print $2}')
    outs=$(echo "$mp" | grep "^Swapouts:" | awk '{print $2}')
    echo "${ins:-0} ${outs:-0}"
}

get_froggy_frozen() {
    echo '{"cmd":"pressure"}' \
        | nc -U "$FROGGY_SOCKET" -W 1 2>/dev/null \
        | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        t1 = d.get('tier1Frozen', [])
        t2 = d.get('tier2Frozen', [])
        print(len(t1 + t2))
        break
    except: pass
" 2>/dev/null || echo "0"
}

# ── Инференс ───────────────────────────────────────────────────────────────────
run_ollama() {
    local prompt="$1"
    local t0 t1 resp tokens elapsed_ms tps
    t0=$(ms_now)
    resp=$(curl -s --max-time 120 -X POST http://localhost:11434/api/generate \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":$(echo "$prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))'),\"stream\":false}")
    t1=$(ms_now)
    elapsed_ms=$((t1 - t0))
    tokens=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_count',0))" 2>/dev/null || echo "0")
    if [[ "$elapsed_ms" -gt 0 && "$tokens" -gt 0 ]]; then
        tps=$(python3 -c "print(round($tokens / ($elapsed_ms/1000), 1))")
    else
        tps="0"
    fi
    echo "${elapsed_ms} ${tokens} ${tps}"
}

run_froggy() {
    local prompt="$1"
    local t0 t1 tokens elapsed_ms tps reply
    local payload
    payload=$(python3 -c "import json; print(json.dumps({'cmd':'generate','prompt':'''$prompt''','maxTokens':$MAX_TOKENS,'useContext':False}))")
    t0=$(ms_now)
    reply=$(echo "$payload" \
        | nc -U "$FROGGY_SOCKET" -W 5 2>/dev/null \
        | python3 -c "
import sys
chunks = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    import json
    try:
        d = json.loads(line)
        if d.get('type') == 'token': chunks.append(d.get('text',''))
        elif d.get('type') == 'done': break
        elif d.get('ok') == False: break
    except: pass
print(len(chunks))
" 2>/dev/null || echo "0")
    t1=$(ms_now)
    tokens="${reply:-0}"
    elapsed_ms=$((t1 - t0))
    if [[ "$elapsed_ms" -gt 0 && "$tokens" -gt 0 ]]; then
        tps=$(python3 -c "print(round($tokens / ($elapsed_ms/1000), 1))")
    else
        tps="0"
    fi
    echo "${elapsed_ms} ${tokens} ${tps}"
}

# ── Проверка готовности ────────────────────────────────────────────────────────
check_ready() {
    if [[ "$SESSION" == "ollama" ]]; then
        curl -s --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1 || {
            echo "Ollama не отвечает. Запусти: ollama serve" >&2; exit 1
        }
        log "Ollama доступна."
    else
        [[ -S "$FROGGY_SOCKET" ]] || {
            echo "Froggy socket не найден: $FROGGY_SOCKET" >&2; exit 1
        }
        local status
        status=$(echo '{"cmd":"status"}' | nc -U "$FROGGY_SOCKET" -W 2 2>/dev/null)
        echo "$status" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        if not d.get('modelLoaded'):
            print('Модель не загружена. Запусти: froggy load <path>', file=sys.stderr)
            sys.exit(1)
        break
    except: pass
" || exit 1
        log "Froggy daemon готов."
    fi
}

# ── Инициализация CSV ──────────────────────────────────────────────────────────
init_csv() {
    echo "timestamp_unix,elapsed_sec,free_mb,active_mb,inactive_mb,wired_mb,compressed_mb,swapins_delta,swapouts_delta,free_pct,frozen_procs" \
        > "$METRICS_CSV"
    echo "timestamp_unix,elapsed_sec,prompt_index,elapsed_ms,tokens,tps" \
        > "$PROMPTS_CSV"
}

# ── Цикл метрик (фон) ──────────────────────────────────────────────────────────
metrics_loop() {
    local start_ts=$1
    local prev_swapins=0 prev_swapouts=0
    local first=true

    while true; do
        local now elapsed vm free_p active_p inactive_p wired_p compressed_p
        local swap_counts swapins swapouts si_delta so_delta free_pct frozen

        now=$(date +%s)
        elapsed=$((now - start_ts))
        vm=$(vm_stat)

        free_p=$(parse_vm_stat_page "$vm" "Pages free:")
        active_p=$(parse_vm_stat_page "$vm" "Pages active:")
        inactive_p=$(parse_vm_stat_page "$vm" "Pages inactive:")
        wired_p=$(parse_vm_stat_page "$vm" "Pages wired down:")
        compressed_p=$(parse_vm_stat_page "$vm" "Pages used by compressor:")

        # В MB (страница = 16 KB)
        free_mb=$(( ${free_p:-0} * 16 / 1024 ))
        active_mb=$(( ${active_p:-0} * 16 / 1024 ))
        inactive_mb=$(( ${inactive_p:-0} * 16 / 1024 ))
        wired_mb=$(( ${wired_p:-0} * 16 / 1024 ))
        compressed_mb=$(( ${compressed_p:-0} * 16 / 1024 ))

        read -r swapins swapouts <<< "$(get_swap_counts)"
        if $first; then
            si_delta=0; so_delta=0; first=false
        else
            si_delta=$(( swapins - prev_swapins ))
            so_delta=$(( swapouts - prev_swapouts ))
        fi
        prev_swapins=$swapins
        prev_swapouts=$swapouts

        free_pct=$(get_pressure_level)

        if [[ "$SESSION" == "froggy" ]]; then
            frozen=$(get_froggy_frozen)
        else
            frozen=0
        fi

        echo "${now},${elapsed},${free_mb},${active_mb},${inactive_mb},${wired_mb},${compressed_mb},${si_delta},${so_delta},${free_pct},${frozen}" \
            >> "$METRICS_CSV"

        sleep "$METRICS_INTERVAL"
    done
}

# ── Цикл промптов (фон) ────────────────────────────────────────────────────────
prompts_loop() {
    local start_ts=$1
    local idx=0

    # Первый промпт сразу через 30с после старта
    sleep 30

    while true; do
        local prompt="${PROMPTS[$((idx % PROMPT_COUNT))]}"
        local now elapsed result elapsed_ms tokens tps

        now=$(date +%s)
        elapsed=$((now - start_ts))
        log "Промпт $((idx+1)): ${prompt:0:60}…"

        if [[ "$SESSION" == "ollama" ]]; then
            read -r elapsed_ms tokens tps <<< "$(run_ollama "$prompt")"
        else
            read -r elapsed_ms tokens tps <<< "$(run_froggy "$prompt")"
        fi

        log "  → ${tokens} токенов, ${tps} tok/s, ${elapsed_ms}ms"
        echo "${now},${elapsed},$((idx+1)),${elapsed_ms},${tokens},${tps}" >> "$PROMPTS_CSV"

        idx=$((idx + 1))
        sleep "$PROMPT_INTERVAL"
    done
}

# ── Summary ────────────────────────────────────────────────────────────────────
write_summary() {
    local start_ts=$1 end_ts=$2
    {
        echo "=== Benchmark Summary: $SESSION ==="
        echo "Start:    $(date -r "$start_ts" '+%Y-%m-%d %H:%M:%S')"
        echo "End:      $(date -r "$end_ts" '+%Y-%m-%d %H:%M:%S')"
        echo "Duration: $(( (end_ts - start_ts) / 60 )) min"
        echo ""
        echo "Model:    $([[ "$SESSION" == "ollama" ]] && echo "$OLLAMA_MODEL" || echo "$FROGGY_MODEL")"
        echo ""
        echo "--- Memory (averages) ---"
        python3 - "$METRICS_CSV" <<'EOF'
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows: sys.exit()
def avg(k): return round(sum(float(r[k]) for r in rows) / len(rows))
print(f"  Free avg:        {avg('free_mb')} MB")
print(f"  Active avg:      {avg('active_mb')} MB")
print(f"  Compressed avg:  {avg('compressed_mb')} MB")
print(f"  Wired avg:       {avg('wired_mb')} MB")
total_si = sum(int(r['swapins_delta']) for r in rows)
total_so = sum(int(r['swapouts_delta']) for r in rows)
print(f"  Total swapins:   {total_si} pages ({total_si*16//1024} MB)")
print(f"  Total swapouts:  {total_so} pages ({total_so*16//1024} MB)")
if rows[0].get('frozen_procs') is not None:
    avg_frozen = avg('frozen_procs')
    print(f"  Avg frozen procs: {avg_frozen}")
EOF
        echo ""
        echo "--- Inference (averages) ---"
        python3 - "$PROMPTS_CSV" <<'EOF'
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows: sys.exit()
tps_vals = [float(r['tps']) for r in rows if float(r.get('tps',0)) > 0]
ms_vals  = [float(r['elapsed_ms']) for r in rows if float(r.get('elapsed_ms',0)) > 0]
print(f"  Prompts sent:    {len(rows)}")
if tps_vals: print(f"  Avg tok/s:       {round(sum(tps_vals)/len(tps_vals), 1)}")
if ms_vals:  print(f"  Avg latency:     {round(sum(ms_vals)/len(ms_vals))} ms")
EOF
        echo ""
        echo "--- Files ---"
        echo "  Metrics: $METRICS_CSV"
        echo "  Prompts: $PROMPTS_CSV"
    } | tee "$SUMMARY_TXT"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    log "=== Benchmark: $SESSION, $(date) ==="
    log "Длительность: $((DURATION_SEC/60)) мин | Метрики: каждые ${METRICS_INTERVAL}с | Промпты: каждые $((PROMPT_INTERVAL/60))мин"
    echo ""

    check_ready
    init_csv

    START_TS=$(date +%s)
    log "Старт. Ctrl+C для досрочной остановки."
    log "Instruments: открой → File → Attach to Process → FroggyDaemon (для Froggy-сессии)"
    echo ""

    # Запускаем фоновые циклы
    metrics_loop "$START_TS" &
    METRICS_PID=$!

    prompts_loop "$START_TS" &
    PROMPTS_PID=$!

    # Ждём DURATION_SEC или Ctrl+C
    trap 'log "Прерывание…"' INT
    sleep "$DURATION_SEC" || true
    trap - INT

    kill "$METRICS_PID" "$PROMPTS_PID" 2>/dev/null || true
    wait "$METRICS_PID" "$PROMPTS_PID" 2>/dev/null || true

    END_TS=$(date +%s)
    echo ""
    write_summary "$START_TS" "$END_TS"
    log "Готово. Результаты в $OUT_DIR/"
}

main
