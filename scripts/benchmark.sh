#!/bin/bash
# benchmark.sh — сравниваем LM Studio / Ollama / Froggy: память, свап, скорость инференса
#
# Использование: ./scripts/benchmark.sh [lmstudio|ollama|froggy] [--power]
#   --power  собирать powermetrics (требует sudo, запускать как: sudo -E ./benchmark.sh ...)
#
# Что сравниваем: НЕ просто модели, а подходы к memory orchestration:
#   lmstudio — llama.cpp (LM Studio API localhost:1234), macOS управляет памятью стандартно
#   ollama   — стандартный запуск, macOS управляет памятью стандартно
#   froggy   — MLX daemon с freeze/thaw + forced pageout фоновых приложений
#
# Рекомендуемый порядок: lmstudio → froggy (одна и та же архитектура модели — Llama 3.2 1B)
#
# Длительность: 60 минут. Запускать после перезагрузки, чистое состояние.
#
# Выход (в benchmark-results/):
#   benchmark-metrics-SESSION-TS.csv   — vm_stat + ps top-10 каждые 30с
#   benchmark-prompts-SESSION-TS.csv   — latency + tok/s на каждый промпт
#   benchmark-procs-SESSION-TS.csv     — RSS топ-процессов каждые 30с
#   benchmark-summary-SESSION-TS.txt   — итоговый отчёт

set -euo pipefail

# ── Параметры ──────────────────────────────────────────────────────────────────
SESSION="${1:?Использование: ./scripts/benchmark.sh [lmstudio|ollama|froggy] [--power]}"
[[ "$SESSION" == "lmstudio" || "$SESSION" == "ollama" || "$SESSION" == "froggy" ]] || {
    echo "SESSION должен быть 'lmstudio', 'ollama' или 'froggy'" >&2; exit 1
}
POWER_MODE=false
[[ "${2:-}" == "--power" ]] && POWER_MODE=true

DURATION_SEC=3600
METRICS_INTERVAL=30
PROMPT_INTERVAL=300

# Модели: Llama 3.2 1B существует в обоих форматах — чистое сравнение без разницы моделей
LMSTUDIO_URL="http://localhost:1234/v1"
LMSTUDIO_MODEL=""          # если пусто — определяется автоматически из /v1/models
OLLAMA_MODEL="llama3.2:1b-instruct-q4_K_M"
FROGGY_MODEL="qwen3-4b-4bit"
FROGGY_SOCKET="$HOME/Library/Application Support/Froggy/froggy.sock"
MAX_TOKENS=200

TS=$(date +%Y%m%d-%H%M%S)
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/benchmark-results"
mkdir -p "$OUT_DIR"
METRICS_CSV="$OUT_DIR/benchmark-metrics-${SESSION}-${TS}.csv"
PROMPTS_CSV="$OUT_DIR/benchmark-prompts-${SESSION}-${TS}.csv"
PROCS_CSV="$OUT_DIR/benchmark-procs-${SESSION}-${TS}.csv"
POWER_LOG="$OUT_DIR/benchmark-power-${SESSION}-${TS}.json"
SUMMARY_TXT="$OUT_DIR/benchmark-summary-${SESSION}-${TS}.txt"

# ── Промпты ────────────────────────────────────────────────────────────────────
# Три группы: simple (быстрый ответ), medium (reasoning), heavy (chain-of-thought).
# Одинаковы для обеих сессий.
PROMPTS=(
    # simple — короткий ответ
    "What is the capital of France? Answer in one sentence."
    "What is the difference between SIGSTOP and SIGKILL in Unix?"
    "Write a bash one-liner to find the 5 largest files in the current directory."

    # medium — код + объяснение
    "Write a Swift function that reverses a string without using built-in reverse methods."
    "Write a Python function to calculate Fibonacci up to n terms, using memoization."
    "Write a SQL query to find duplicate email addresses in a users table with their count."
    "Explain what a KV-cache is in LLM inference and why quantizing it saves memory."
    "What is unified memory and why does it matter specifically for running LLMs on MacBooks?"

    # heavy — многошаговое рассуждение, нагружает KV-cache
    "You are debugging a macOS app that crashes with EXC_BAD_ACCESS. Walk me through a systematic 5-step debugging process, including what tools to use at each step and what signals to look for."
    "Compare SIGSTOP+pageout vs jetsam as memory reclaim strategies on macOS. For each: explain the mechanism, list the trade-offs, and describe when you would prefer one over the other. Be specific."
    "Design a memory pressure management system for a Mac with 8 GB unified memory running a local LLM. Describe the architecture, the signals you would monitor, the actions at each pressure tier, and how you would avoid freezing critical processes."
    "Explain step by step how Apple Silicon's unified memory architecture changes the performance characteristics of running transformer models compared to discrete GPU systems. Cover memory bandwidth, cache hierarchy, and quantization implications."
)
PROMPT_COUNT=${#PROMPTS[@]}

# ── Хелперы ────────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
ms_now() { python3 -c "import time; print(int(time.time()*1000))"; }

parse_vm_page() { echo "$1" | grep "$2" | awk '{print $NF}' | tr -d '.'; }

get_swap_counts() {
    local mp; mp=$(memory_pressure 2>/dev/null)
    local ins outs
    ins=$(echo "$mp" | grep "^Swapins:"  | awk '{print $2}')
    outs=$(echo "$mp" | grep "^Swapouts:" | awk '{print $2}')
    echo "${ins:-0} ${outs:-0}"
}

get_free_pct() {
    memory_pressure 2>/dev/null \
        | grep -Eo 'System-wide memory free percentage: [0-9]+' \
        | awk '{print $NF}' || echo "?"
}

get_froggy_frozen() {
    [[ "$SESSION" == "froggy" ]] || { echo "0"; return; }
    echo '{"cmd":"pressure"}' \
        | nc -U "$FROGGY_SOCKET" -W 1 2>/dev/null \
        | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        print(len(d.get('tier1Frozen',[]) + d.get('tier2Frozen',[])))
        break
    except: pass
" 2>/dev/null || echo "0"
}

# ── Инференс ───────────────────────────────────────────────────────────────────
run_lmstudio() {
    local prompt="$1"
    local t0 t1 resp tokens elapsed_ms tps model_id
    model_id="${LMSTUDIO_MODEL:-$(lmstudio_model_id)}"
    t0=$(ms_now)
    resp=$(curl -s --max-time 180 -X POST "${LMSTUDIO_URL}/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "
import sys, json
print(json.dumps({
    'model': '${model_id}',
    'messages': [{'role': 'user', 'content': sys.stdin.read().strip()}],
    'max_tokens': ${MAX_TOKENS},
    'stream': False
}))
" <<< "$prompt")")
    t1=$(ms_now)
    elapsed_ms=$((t1 - t0))
    tokens=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('usage', {}).get('completion_tokens', 0))
except: print(0)
" 2>/dev/null || echo "0")
    tps=$(python3 -c "print(round($tokens/($elapsed_ms/1000),1) if $elapsed_ms>0 and $tokens>0 else 0)")
    echo "${elapsed_ms} ${tokens} ${tps}"
}

lmstudio_model_id() {
    curl -s --max-time 5 "${LMSTUDIO_URL}/models" \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = d.get('data', [])
    if models: print(models[0]['id'])
    else: print('local-model')
except: print('local-model')
" 2>/dev/null || echo "local-model"
}

run_ollama() {
    local prompt="$1"
    local t0 t1 resp tokens elapsed_ms tps
    t0=$(ms_now)
    resp=$(curl -s --max-time 180 -X POST http://localhost:11434/api/generate \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":$(python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))' <<< "$prompt"),\"stream\":false}")
    t1=$(ms_now)
    elapsed_ms=$((t1 - t0))
    tokens=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_count',0))" 2>/dev/null || echo "0")
    tps=$(python3 -c "print(round($tokens/($elapsed_ms/1000),1) if $elapsed_ms>0 and $tokens>0 else 0)")
    echo "${elapsed_ms} ${tokens} ${tps}"
}

run_froggy() {
    local prompt="$1"
    local payload t0 t1 tokens elapsed_ms tps
    payload=$(python3 -c "
import json, sys
p = sys.stdin.read().strip()
print(json.dumps({'cmd':'generate','prompt':p,'maxTokens':$MAX_TOKENS,'useContext':False}))
" <<< "$prompt")
    t0=$(ms_now)
    tokens=$(echo "$payload" \
        | nc -U "$FROGGY_SOCKET" -W 10 2>/dev/null \
        | python3 -c "
import sys, json
n = 0
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        if d.get('type') == 'token': n += 1
        elif d.get('type') == 'done' or d.get('ok') == False: break
    except: pass
print(n)
" 2>/dev/null || echo "0")
    t1=$(ms_now)
    elapsed_ms=$((t1 - t0))
    tps=$(python3 -c "print(round($tokens/($elapsed_ms/1000),1) if $elapsed_ms>0 and $tokens>0 else 0)")
    echo "${elapsed_ms} ${tokens} ${tps}"
}

# ── Проверка готовности ────────────────────────────────────────────────────────
check_ready() {
    if [[ "$SESSION" == "lmstudio" ]]; then
        local model_id
        model_id=$(lmstudio_model_id)
        [[ "$model_id" == "local-model" ]] && {
            curl -s --max-time 5 "${LMSTUDIO_URL}/models" >/dev/null 2>&1 || {
                echo "LM Studio не отвечает. Запусти LM Studio → Local Server → Start Server" >&2; exit 1
            }
            echo "LM Studio API доступна, но моделей не найдено — загрузи модель в LM Studio" >&2; exit 1
        }
        [[ -z "$LMSTUDIO_MODEL" ]] && LMSTUDIO_MODEL="$model_id"
        log "LM Studio доступна (модель: $LMSTUDIO_MODEL)."
    elif [[ "$SESSION" == "ollama" ]]; then
        curl -s --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1 || {
            echo "Ollama не отвечает. Запусти: ollama serve" >&2; exit 1
        }
        log "Ollama доступна (модель: $OLLAMA_MODEL)."
    else
        [[ -S "$FROGGY_SOCKET" ]] || {
            echo "Froggy socket не найден: $FROGGY_SOCKET" >&2; exit 1
        }
        echo '{"cmd":"status"}' | nc -U "$FROGGY_SOCKET" -W 2 2>/dev/null \
            | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        if not d.get('modelLoaded'):
            print('Модель не загружена. froggy load <path>', file=sys.stderr); sys.exit(1)
        break
    except: pass
" || exit 1
        log "Froggy daemon готов (модель: $FROGGY_MODEL)."
    fi
    if $POWER_MODE && [[ "$EUID" -ne 0 ]]; then
        echo "--power требует sudo. Запусти: sudo -E $0 $SESSION --power" >&2; exit 1
    fi
}

# ── Инициализация CSV ──────────────────────────────────────────────────────────
init_csv() {
    echo "timestamp_unix,elapsed_sec,free_mb,active_mb,inactive_mb,wired_mb,compressed_mb,purgeable_mb,speculative_mb,swapins_delta,swapouts_delta,free_pct,frozen_procs" \
        > "$METRICS_CSV"
    echo "timestamp_unix,elapsed_sec,prompt_index,prompt_type,elapsed_ms,tokens,tps" \
        > "$PROMPTS_CSV"
    echo "timestamp_unix,elapsed_sec,pid,comm,rss_mb,cpu_pct" \
        > "$PROCS_CSV"
}

# ── Цикл метрик ────────────────────────────────────────────────────────────────
metrics_loop() {
    local start_ts=$1
    local prev_si=0 prev_so=0 first=true

    while true; do
        local now elapsed vm
        now=$(date +%s); elapsed=$((now - start_ts))
        vm=$(vm_stat)

        local fp ap ip wp cp pp sp
        fp=$(parse_vm_page "$vm" "Pages free:")
        ap=$(parse_vm_page "$vm" "Pages active:")
        ip=$(parse_vm_page "$vm" "Pages inactive:")
        wp=$(parse_vm_page "$vm" "Pages wired down:")
        cp=$(parse_vm_page "$vm" "Pages used by compressor:")
        pp=$(parse_vm_page "$vm" "Pages purgeable:")
        sp=$(parse_vm_page "$vm" "Pages speculative:")

        local to_mb="* 16 / 1024"
        local free_mb=$(( ${fp:-0} $to_mb ))
        local active_mb=$(( ${ap:-0} $to_mb ))
        local inactive_mb=$(( ${ip:-0} $to_mb ))
        local wired_mb=$(( ${wp:-0} $to_mb ))
        local compressed_mb=$(( ${cp:-0} $to_mb ))
        local purgeable_mb=$(( ${pp:-0} $to_mb ))
        local speculative_mb=$(( ${sp:-0} $to_mb ))

        local si so si_d so_d
        read -r si so <<< "$(get_swap_counts)"
        if $first; then si_d=0; so_d=0; first=false
        else si_d=$((si - prev_si)); so_d=$((so - prev_so)); fi
        prev_si=$si; prev_so=$so

        local free_pct frozen
        free_pct=$(get_free_pct)
        frozen=$(get_froggy_frozen)

        echo "${now},${elapsed},${free_mb},${active_mb},${inactive_mb},${wired_mb},${compressed_mb},${purgeable_mb},${speculative_mb},${si_d},${so_d},${free_pct},${frozen}" \
            >> "$METRICS_CSV"

        # Top-10 процессов по RSS
        ps -ax -o pid=,comm=,rss=,%cpu= 2>/dev/null \
            | sort -rn -k3 | head -10 \
            | while read -r pid comm rss cpu; do
                local rss_mb=$(( ${rss:-0} / 1024 ))
                echo "${now},${elapsed},${pid},${comm},${rss_mb},${cpu}" >> "$PROCS_CSV"
              done

        sleep "$METRICS_INTERVAL"
    done
}

# ── Цикл промптов ──────────────────────────────────────────────────────────────
prompts_loop() {
    local start_ts=$1
    local idx=0
    sleep 30  # первый промпт через 30с

    while true; do
        local prompt="${PROMPTS[$((idx % PROMPT_COUNT))]}"
        local ptype now elapsed elapsed_ms tokens tps

        # Определяем тип промпта по индексу
        local raw_idx=$((idx % PROMPT_COUNT))
        if   (( raw_idx < 3  )); then ptype="simple"
        elif (( raw_idx < 8  )); then ptype="medium"
        else                          ptype="heavy"; fi

        now=$(date +%s); elapsed=$((now - start_ts))
        log "Промпт $((idx+1)) [${ptype}]: ${prompt:0:55}…"

        case "$SESSION" in
            lmstudio) read -r elapsed_ms tokens tps <<< "$(run_lmstudio "$prompt")" ;;
            ollama)   read -r elapsed_ms tokens tps <<< "$(run_ollama "$prompt")" ;;
            froggy)   read -r elapsed_ms tokens tps <<< "$(run_froggy "$prompt")" ;;
        esac

        log "  → ${tokens} tok, ${tps} tok/s, ${elapsed_ms}ms"
        echo "${now},${elapsed},$((idx+1)),${ptype},${elapsed_ms},${tokens},${tps}" >> "$PROMPTS_CSV"

        idx=$((idx + 1))
        sleep "$PROMPT_INTERVAL"
    done
}

# ── powermetrics (опционально, sudo) ───────────────────────────────────────────
power_loop() {
    powermetrics --samplers cpu_power,gpu_power -i 5000 -f json \
        >> "$POWER_LOG" 2>/dev/null &
    echo $!
}

# ── Summary ────────────────────────────────────────────────────────────────────
write_summary() {
    local start_ts=$1 end_ts=$2
    {
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  Benchmark Summary: $SESSION"
        printf "║  %-56s║\n" "$(date -r "$start_ts" '+%Y-%m-%d %H:%M:%S') → $(date -r "$end_ts" '+%H:%M:%S')"
        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
        echo "КОНТЕКСТ СРАВНЕНИЯ"
        echo "  Тестируем не модели — тестируем memory orchestration:"
        case "$SESSION" in
            lmstudio) echo "  lmstudio ($LMSTUDIO_MODEL) — llama.cpp, macOS управляет памятью стандартно" ;;
            ollama)   echo "  ollama ($OLLAMA_MODEL) — macOS управляет памятью стандартно" ;;
            froggy)   echo "  froggy ($FROGGY_MODEL) — MLX, freeze/thaw + forced pageout фоновых app" ;;
        esac
        echo ""
        echo "ПАМЯТЬ (средние за сессию)"
        python3 - "$METRICS_CSV" <<'PYEOF'
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows: sys.exit()
def avg(k): return round(sum(float(r[k]) for r in rows if r.get(k,'').strip()) / max(len(rows),1))
def total(k): return sum(int(r[k]) for r in rows if r.get(k,'').strip().lstrip('-').isdigit())
print(f"  Free avg:          {avg('free_mb')} MB")
print(f"  Active avg:        {avg('active_mb')} MB")
print(f"  Compressed avg:    {avg('compressed_mb')} MB")
print(f"  Wired avg:         {avg('wired_mb')} MB")
print(f"  Purgeable avg:     {avg('purgeable_mb')} MB")
si = total('swapins_delta');  so = total('swapouts_delta')
print(f"  Total swapins:     {si} pages ({si*16//1024} MB)")
print(f"  Total swapouts:    {so} pages ({so*16//1024} MB)")
fz = [float(r['frozen_procs']) for r in rows if r.get('frozen_procs','0').isdigit()]
if any(f > 0 for f in fz):
    print(f"  Avg frozen procs:  {round(sum(fz)/len(fz),1)}")
PYEOF
        echo ""
        echo "ИНФЕРЕНС"
        python3 - "$PROMPTS_CSV" <<'PYEOF'
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows: sys.exit()
for ptype in ['simple','medium','heavy']:
    subset = [r for r in rows if r.get('prompt_type') == ptype]
    if not subset: continue
    tps  = [float(r['tps']) for r in subset if float(r.get('tps',0)) > 0]
    ms   = [float(r['elapsed_ms']) for r in subset if float(r.get('elapsed_ms',0)) > 0]
    print(f"  [{ptype:6}]  n={len(subset)}  "
          f"avg {round(sum(ms)/len(ms)) if ms else '?'} ms  "
          f"{round(sum(tps)/len(tps),1) if tps else '?'} tok/s")
PYEOF
        echo ""
        echo "ФАЙЛЫ"
        echo "  $METRICS_CSV"
        echo "  $PROMPTS_CSV"
        echo "  $PROCS_CSV"
        $POWER_MODE && echo "  $POWER_LOG"
        echo ""
        echo "Instruments (для Froggy): Xcode → Open Developer Tool → Instruments"
        echo "  → File → Attach → FroggyDaemon → Points of Interest + VM Tracker"
    } | tee "$SUMMARY_TXT"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    [[ "$SESSION" == "froggy" ]] && \
        log "Убедись: Froggy запущен с моделью $FROGGY_MODEL (froggy load ~/models/$FROGGY_MODEL)"
    [[ "$SESSION" == "lmstudio" ]] && \
        log "Убедись: LM Studio → Local Server → Start Server, модель загружена"
    log "=== Benchmark: $SESSION | $(date) ==="
    log "Длительность: $((DURATION_SEC/60)) мин | Метрики: ${METRICS_INTERVAL}с | Промпты: $((PROMPT_INTERVAL/60)) мин"
    $POWER_MODE && log "Power mode: ON (powermetrics активен)"
    echo ""

    check_ready
    init_csv

    START_TS=$(date +%s)
    log "Старт. Ctrl+C для досрочной остановки."
    [[ "$SESSION" == "froggy" ]] && \
        log "Instruments: Xcode → Open Developer Tool → Instruments → Attach → FroggyDaemon"
    echo ""

    metrics_loop "$START_TS" &
    METRICS_PID=$!

    prompts_loop "$START_TS" &
    PROMPTS_PID=$!

    POWER_PID=""
    if $POWER_MODE; then
        POWER_PID=$(power_loop)
        log "powermetrics PID: $POWER_PID → $POWER_LOG"
    fi

    trap 'log "Прерывание по Ctrl+C…"' INT
    sleep "$DURATION_SEC" || true
    trap - INT

    kill "$METRICS_PID" "$PROMPTS_PID" ${POWER_PID:+$POWER_PID} 2>/dev/null || true
    wait  "$METRICS_PID" "$PROMPTS_PID" 2>/dev/null || true

    END_TS=$(date +%s)
    echo ""
    write_summary "$START_TS" "$END_TS"
    log "Готово. Результаты: $OUT_DIR/"
}

main
