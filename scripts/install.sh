#!/bin/bash
# Устанавливает Froggy из zip-артефакта GitHub Release.
# Использование: ./scripts/install.sh [path/to/froggy-vX.Y.Z-arm64.zip]
# Без аргумента — скачивает последний релиз через gh CLI.
set -euo pipefail

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin}"
INSTALL_LIBEXEC="${INSTALL_LIBEXEC:-/usr/local/libexec}"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
# Label сервиса в launchd — без суффикса «.plist». Раньше bootout звался с
# суффиксом, попадал в `2>/dev/null || true` и никогда не срабатывал: бинарники
# менялись под живым демоном, а следующий bootstrap падал «already loaded».
LABEL="com.froggychips.froggy"
PLIST="$LABEL.plist"

# Приватный рабочий каталог (mktemp под $TMPDIR пользователя). Скачивание и
# распаковка идут ТОЛЬКО сюда. Раньше zip качался в общий /tmp и выбирался
# `ls /tmp/froggy-*.zip | sort -V | tail -1` — другой локальный пользователь
# мог заранее положить туда froggy-v9999-arm64.zip, и он ставился через sudo.
# Заодно чинит повторный запуск: gh не перезаписывает уже существующий файл.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- найти / скачать zip ---
if [[ $# -ge 1 ]]; then
    ZIP="$1"
else
    if ! command -v gh &>/dev/null; then
        echo "gh CLI не найден. Установи его: brew install gh" >&2
        exit 1
    fi
    echo "Скачиваю последний релиз..."
    mkdir -p "$WORK/dl"
    gh release download --repo froggychips/Froggy --pattern "froggy-*-arm64.zip" --dir "$WORK/dl"
    shopt -s nullglob
    candidates=("$WORK"/dl/froggy-*-arm64.zip)
    shopt -u nullglob
    if [[ ${#candidates[@]} -ne 1 ]]; then
        echo "Ожидал ровно один артефакт froggy-*-arm64.zip, получил ${#candidates[@]}" >&2
        exit 1
    fi
    ZIP="${candidates[0]}"
fi

[[ -f "$ZIP" ]] || { echo "Файл не найден: $ZIP" >&2; exit 1; }

echo "Распаковываю $ZIP..."
mkdir -p "$WORK/unpacked"
unzip -q "$ZIP" -d "$WORK/unpacked"
shopt -s nullglob
dists=("$WORK"/unpacked/*/)
shopt -u nullglob
if [[ ${#dists[@]} -ne 1 ]]; then
    echo "Ожидал один каталог в архиве, получил ${#dists[@]}" >&2
    exit 1
fi
BASE="${dists[0]%/}"

# --- сначала выгружаем работающий демон ---
# Иначе бинарники заменяются под живым процессом (старый демон продолжает
# работать с новыми worker-бинарями), а bootstrap ниже падает.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "Выгружаю работающий LaunchAgent $LABEL..."
    launchctl bootout "gui/$(id -u)/$LABEL"
fi

# --- бинари ---
echo "Устанавливаю CLI в $INSTALL_BIN..."
[[ -f "$BASE/froggy" ]] && sudo install -m 755 "$BASE/froggy" "$INSTALL_BIN/froggy"

echo "Устанавливаю daemon и worker'ы в $INSTALL_LIBEXEC..."
sudo mkdir -p "$INSTALL_LIBEXEC"
[[ -f "$BASE/FroggyDaemon" ]] && sudo install -m 755 "$BASE/FroggyDaemon" "$INSTALL_LIBEXEC/FroggyDaemon"
[[ -f "$BASE/FroggyMLXWorker" ]] && sudo install -m 755 "$BASE/FroggyMLXWorker" "$INSTALL_LIBEXEC/FroggyMLXWorker"
[[ -f "$BASE/FroggyAudioWorker" ]] && sudo install -m 755 "$BASE/FroggyAudioWorker" "$INSTALL_LIBEXEC/FroggyAudioWorker"
[[ -f "$BASE/FroggyMenuBar" ]] && sudo install -m 755 "$BASE/FroggyMenuBar" "$INSTALL_LIBEXEC/FroggyMenuBar"

# --- metallib ---
RESOURCES_DST="$INSTALL_LIBEXEC/Resources"
sudo mkdir -p "$RESOURCES_DST"
[[ -f "$BASE/Resources/default.metallib" ]] && \
    sudo install -m 644 "$BASE/Resources/default.metallib" "$RESOURCES_DST/default.metallib"

# --- LaunchAgent ---
mkdir -p "$LAUNCHAGENT_DIR"
PLIST_SRC="$BASE/LaunchAgent/$PLIST"
if [[ -f "$PLIST_SRC" ]]; then
    cp "$PLIST_SRC" "$LAUNCHAGENT_DIR/$PLIST"
    # Подставляем реальный путь к бинарю
    sed -i '' "s|/usr/local/libexec/FroggyDaemon|$INSTALL_LIBEXEC/FroggyDaemon|g" \
        "$LAUNCHAGENT_DIR/$PLIST"
    launchctl bootstrap "gui/$(id -u)" "$LAUNCHAGENT_DIR/$PLIST"
    echo "LaunchAgent загружен."
fi

# --- playbooks (Claude Code commands) ---
if [[ -d "$BASE/playbooks" ]]; then
    mkdir -p "$HOME/.claude/commands"
    cp "$BASE/playbooks/"*.md "$HOME/.claude/commands/"
    echo "Playbooks скопированы в ~/.claude/commands/"
fi

echo ""
echo "Установка завершена."
echo ""
echo "Следующий шаг — указать модель:"
echo "  froggy load ~/models/<mlx-model-dir>"
echo ""
echo "Или скачать модель с HuggingFace:"
echo "  pip install huggingface_hub"
echo "  huggingface-cli download mlx-community/Qwen2.5-3B-Instruct-4bit --local-dir ~/models/qwen2.5-3b-4bit"
