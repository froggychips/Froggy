#!/usr/bin/env bash
# Session-summary aggregator: собирает в один bundle всё, что Froggy
# успел накопить за сессию использования — для post-session анализа
# (closing validation gate ADR-0011, AD-1 scope decision, UX-debt list).
#
# Что попадает в bundle:
#   1. log.logarchive       — unified log по `subsystem == "com.froggychips.froggy"`
#                             за указанный период (через scripts/logbundle.sh)
#   2. freeze_events.tsv    — SQLite dump таблицы `events` из freeze_stats.sqlite
#                             (Mem-5 этап 1 телеметрия)
#   3. frozen_pids.txt      — текущее состояние FrozenPidsStore
#   4. config.snapshot.json — snapshot настроек (на случай если менял в процессе)
#   5. system.txt           — vm_stat + memory_pressure + uname на момент сбора
#   6. ipc/                 — JSON-снимки IPC-команд (status/pressure/accessors)
#                             если демон запущен; иначе — DAEMON_DOWN.txt
#   7. notes.md             — заглушка для ручных пометок («18:42 Discord SIGSTOP
#                             при наборе» и т.п.)
#   8. MANIFEST.txt         — что собрано, что пропущено и почему
#
# Each step best-effort — если демон не запущен, SQLite пустой, config.json
# не существует — соответствующий артефакт пропускается с пометкой в MANIFEST.
#
# Idempotent: создаёт `froggy-session-<UTC-timestamp>/` рядом, не трёт
# существующие. По умолчанию tarball'ит результат и удаляет директорию;
# `--no-tar` оставляет директорию как есть.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Froggy"
SOCK="$SUPPORT_DIR/froggy.sock"
FROGGY_BIN="$ROOT/.build/release/froggy"
[ -x "$FROGGY_BIN" ] || FROGGY_BIN="$ROOT/.build/arm64-apple-macosx/release/froggy"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
default_out="./froggy-session-${ts}"

out=""
last="1h"
do_tar=1

usage() {
    cat <<EOF
usage: $(basename "$0") [-o <output_dir>] [--last <duration>] [--no-tar]

Собирает session-summary bundle для post-session анализа.

  -o <dir>          куда положить bundle (default: ./froggy-session-<ts>)
  --last <duration> период для unified log: 30m, 1h, 4h, 1d (default: 1h)
  --no-tar          не tarball'ить — оставить директорию
  -h, --help        эта справка

После сбора печатает финальный путь, размер и краткий MANIFEST.

Best-effort: если что-то недоступно (daemon down, SQLite пустой) —
пропускается с пометкой в MANIFEST.txt, не валит весь сбор.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o)
            if [ $# -lt 2 ]; then
                echo "ERROR: -o требует аргумент" >&2
                exit 2
            fi
            out="$2"
            shift 2
            ;;
        --last)
            if [ $# -lt 2 ]; then
                echo "ERROR: --last требует аргумент (e.g. 1h, 30m)" >&2
                exit 2
            fi
            last="$2"
            shift 2
            ;;
        --no-tar)
            do_tar=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: неизвестный аргумент: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -z "$out" ] && out="$default_out"

if [ -e "$out" ]; then
    echo "ERROR: $out уже существует. Удали или передай другой -o." >&2
    exit 1
fi

mkdir -p "$out"
manifest="$out/MANIFEST.txt"
{
    echo "# Froggy session-summary bundle"
    echo "# created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# host:    $(uname -mnsr)"
    echo
} > "$manifest"

note() {
    # шортcut для пишем-в-manifest-и-stdout
    echo "$1"
    echo "$1" >> "$manifest"
}

# 1. unified log archive (через logbundle.sh)
note "[1/8] log.logarchive (--last $last)"
if [ -x "$ROOT/scripts/logbundle.sh" ]; then
    if "$ROOT/scripts/logbundle.sh" -o "$out/log.logarchive" --last "$last" \
       >/dev/null 2>"$out/log.error.txt"; then
        rm -f "$out/log.error.txt"
        note "    OK: $(du -sh "$out/log.logarchive" 2>/dev/null | awk '{print $1}')"
    else
        note "    SKIPPED: log collect failed (см. log.error.txt)"
    fi
else
    note "    SKIPPED: scripts/logbundle.sh не найден"
fi

# 2. SQLite freeze_events dump
note "[2/8] freeze_events.tsv (Mem-5 телеметрия)"
sqlite_db="$SUPPORT_DIR/freeze_stats.sqlite"
if [ -f "$sqlite_db" ]; then
    if sqlite3 "$sqlite_db" \
        "SELECT datetime(ts,'unixepoch') AS ts_utc, * FROM events ORDER BY ts" \
        > "$out/freeze_events.tsv" 2>"$out/freeze_events.error.txt"; then
        rm -f "$out/freeze_events.error.txt"
        rows=$(wc -l < "$out/freeze_events.tsv" | tr -d ' ')
        note "    OK: $rows rows"
    else
        note "    SKIPPED: sqlite3 query failed (см. freeze_events.error.txt)"
    fi
else
    note "    SKIPPED: $sqlite_db не существует (демон ни разу не писал)"
fi

# 3. frozen.pids state
note "[3/8] frozen_pids.txt"
frozen_pids="$SUPPORT_DIR/frozen.pids"
if [ -f "$frozen_pids" ]; then
    cp "$frozen_pids" "$out/frozen_pids.txt"
    note "    OK: $(wc -l < "$frozen_pids" | tr -d ' ') lines"
else
    note "    SKIPPED: frozen.pids не существует (никого не морозили)"
fi

# 4. config snapshot
note "[4/8] config.snapshot.json"
config_json="$SUPPORT_DIR/config.json"
if [ -f "$config_json" ]; then
    cp "$config_json" "$out/config.snapshot.json"
    note "    OK: $(wc -c < "$config_json" | tr -d ' ') bytes"
else
    note "    SKIPPED: config.json не существует (используются defaults)"
fi

# 5. system snapshot
note "[5/8] system.txt"
{
    echo "=== uname ==="
    uname -mnsr
    echo
    echo "=== vm_stat ==="
    vm_stat 2>/dev/null || echo "vm_stat unavailable"
    echo
    echo "=== memory_pressure ==="
    memory_pressure 2>/dev/null || echo "memory_pressure unavailable"
    echo
    echo "=== sysctl hw.memsize / hw.ncpu ==="
    sysctl hw.memsize hw.ncpu 2>/dev/null || echo "sysctl unavailable"
} > "$out/system.txt"
note "    OK: $(wc -l < "$out/system.txt" | tr -d ' ') lines"

# 6. IPC snapshots — best-effort, daemon может быть down
note "[6/8] ipc/ snapshots"
mkdir -p "$out/ipc"
if [ -S "$SOCK" ]; then
    daemon_up=1
    for cmd in status pressure accessors; do
        out_file="$out/ipc/${cmd}.json"
        if echo "{\"cmd\":\"$cmd\"}" | nc -U "$SOCK" 2>/dev/null > "$out_file"; then
            if [ -s "$out_file" ]; then
                note "    ipc/${cmd}.json: $(wc -c < "$out_file" | tr -d ' ') bytes"
            else
                rm -f "$out_file"
                note "    ipc/${cmd}.json: empty response, skipped"
            fi
        else
            rm -f "$out_file"
            note "    ipc/${cmd}.json: nc failed"
        fi
    done
else
    echo "Daemon socket $SOCK не существует на момент сбора." > "$out/ipc/DAEMON_DOWN.txt"
    note "    SKIPPED: daemon down (нет $SOCK)"
fi

# 7. notes.md template
note "[7/8] notes.md"
cat > "$out/notes.md" <<'EOF'
# Session notes

Заполни во время / после сессии. Что сюда идёт:

* Embarrassing freeze events: timestamp + bundle_id + что делал
  (например: `18:42 com.hnc.Discord SIGSTOP во время набора`).
* Surprises: «не понимаю почему Froggy сделал X».
* UX-debt: что в MenuBar / CLI / IPC хочется иначе.
* Performance: tok/s от руки замеренные через `time froggy gen ...`.
* Под-pressure scenario: когда поймал warning/critical, что делал в
  этот момент, как Froggy себя вёл.
* Crashes / hangs: timestamp + что предшествовало.
* THESIS criterion #2 check: что Froggy реально дал тебе сегодня,
  чего обычный macOS не дал бы?

## Timeline

(заполни)

## Honest verdict

(заполни в конце)
EOF
note "    OK: template создан"

# 8. tarball (если не --no-tar)
note "[8/8] tarball"
if [ "$do_tar" = "1" ]; then
    tar_path="${out}.tar.gz"
    if tar -czf "$tar_path" -C "$(dirname "$out")" "$(basename "$out")" 2>"$out/tar.error.txt"; then
        rm -f "$out/tar.error.txt"
        rm -rf "$out"
        size=$(du -sh "$tar_path" 2>/dev/null | awk '{print $1}')
        abs=$(cd "$(dirname "$tar_path")" && pwd)/$(basename "$tar_path")
        echo
        echo "OK: $abs ($size)"
        echo "Распаковка: tar -xzf $abs"
    else
        echo "ERROR: tar failed (см. $out/tar.error.txt), оставляю директорию" >&2
        size=$(du -sh "$out" 2>/dev/null | awk '{print $1}')
        echo "Bundle directory: $out ($size)"
        exit 1
    fi
else
    size=$(du -sh "$out" 2>/dev/null | awk '{print $1}')
    abs=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")
    echo
    echo "OK: $abs ($size)"
fi
