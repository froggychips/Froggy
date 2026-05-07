#!/usr/bin/env bash
# Собирает unified-log архив (`.logarchive`) только по событиям с
# `subsystem == "com.froggychips.froggy"` — для прикрепления к bug-report'у
# от внешних пользователей. Без entitlement'ов, без особых прав; всё что
# нужно есть в любой macOS-инсталляции.
#
# Why a wrapper и не «просто скажи юзеру дёрнуть `log collect`»:
#  * Предикат длинный, легко опечататься в issue-комментарии.
#  * `log collect` без `--predicate` тащит весь системный лог (десятки MB
#    и приватные данные других приложений). Этот скрипт сужает выборку до
#    Froggy-событий — и репортить безопаснее, и архив компактный.
#  * `--last <duration>` даёт юзеру возможность не тащить всю историю
#    с момента boot'а — обычно достаточно последнего часа вокруг бага.
#
# Idempotent: если по указанному `-o` пути уже что-то лежит, `log collect`
# сам ругнётся и завершится с ненулевым кодом — мы не трём чужие архивы.
# Хочешь перезапустить — удали старый файл руками или передай новый путь.

set -euo pipefail

SUBSYSTEM='com.froggychips.froggy'
out="./froggy.logarchive"
last=""

usage() {
    cat <<EOF
usage: $(basename "$0") [-o <output_path>] [--last <duration>]

  -o <path>         куда положить .logarchive (default: ./froggy.logarchive)
  --last <duration> ограничить выборку: 30m, 1h, 2d и т.п. (передаётся в
                    \`log collect --last\` как есть)
  -h, --help        эта справка

После сбора печатает финальный путь и размер. Архив можно открыть в
Console.app или прогнать через \`log show <path.logarchive>\`.
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

# Sanity: `log` это часть macOS (/usr/bin/log), но мало ли — кто-то
# запускает на Linux'е по ошибке или PATH побит.
if ! command -v log >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: \`log\` не найден в PATH.

Этот скрипт использует встроенный в macOS \`log collect\` и работает
только на macOS. Если ты на macOS и видишь эту ошибку — проверь, что
\`/usr/bin\` в PATH.
EOF
    exit 1
fi

cmd=(log collect --predicate "subsystem == \"$SUBSYSTEM\"" --output "$out")
if [ -n "$last" ]; then
    cmd+=(--last "$last")
fi

echo "Собираю unified-log архив: predicate='subsystem == \"$SUBSYSTEM\"'${last:+, last=$last}"
echo "Команда: ${cmd[*]}"
"${cmd[@]}"

# `log collect` создаёт .logarchive как директорию (bundle), поэтому
# `du -sh` правильнее чем `stat`.
if [ -e "$out" ]; then
    size=$(du -sh "$out" 2>/dev/null | awk '{print $1}')
    abs_path=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")
    echo "OK: $abs_path ($size)"
else
    echo "ERROR: ожидаемый архив не появился: $out" >&2
    exit 1
fi
