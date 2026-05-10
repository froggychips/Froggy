#!/bin/bash
# Устанавливает Froggy из zip-артефакта GitHub Release.
# Использование: ./scripts/install.sh [path/to/froggy-vX.Y.Z-arm64.zip]
# Без аргумента — скачивает последний релиз через gh CLI.
set -euo pipefail

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin}"
INSTALL_LIBEXEC="${INSTALL_LIBEXEC:-/usr/local/libexec}"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="com.froggychips.froggy.plist"

# --- найти / скачать zip ---
if [[ $# -ge 1 ]]; then
    ZIP="$1"
else
    if ! command -v gh &>/dev/null; then
        echo "gh CLI не найден. Установи его: brew install gh" >&2
        exit 1
    fi
    echo "Скачиваю последний релиз..."
    gh release download --repo froggychips/Froggy --pattern "*.zip" --dir /tmp
    ZIP=$(ls /tmp/froggy-*-arm64.zip | sort -V | tail -1)
fi

[[ -f "$ZIP" ]] || { echo "Файл не найден: $ZIP" >&2; exit 1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Распаковываю $ZIP..."
unzip -q "$ZIP" -d "$TMPDIR"
DIST=$(ls "$TMPDIR")
BASE="$TMPDIR/$DIST"

# --- бинари ---
echo "Устанавливаю бинари в $INSTALL_BIN..."
for bin in FroggyDaemon froggy; do
    [[ -f "$BASE/$bin" ]] && sudo install -m 755 "$BASE/$bin" "$INSTALL_BIN/$bin"
done

echo "Устанавливаю FroggyMLXWorker в $INSTALL_LIBEXEC..."
sudo mkdir -p "$INSTALL_LIBEXEC"
[[ -f "$BASE/FroggyMLXWorker" ]] && sudo install -m 755 "$BASE/FroggyMLXWorker" "$INSTALL_LIBEXEC/FroggyMLXWorker"

# --- metallib ---
RESOURCES_DST="/usr/local/libexec/FroggyResources"
sudo mkdir -p "$RESOURCES_DST"
[[ -f "$BASE/Resources/default.metallib" ]] && \
    sudo cp "$BASE/Resources/default.metallib" "$RESOURCES_DST/default.metallib"

# --- LaunchAgent ---
mkdir -p "$LAUNCHAGENT_DIR"
PLIST_SRC="$BASE/LaunchAgent/$PLIST"
if [[ -f "$PLIST_SRC" ]]; then
    cp "$PLIST_SRC" "$LAUNCHAGENT_DIR/$PLIST"
    # Подставляем реальный путь к бинарю
    sed -i '' "s|/usr/local/bin/FroggyDaemon|$INSTALL_BIN/FroggyDaemon|g" \
        "$LAUNCHAGENT_DIR/$PLIST"
    launchctl bootout "gui/$(id -u)/$PLIST" 2>/dev/null || true
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
