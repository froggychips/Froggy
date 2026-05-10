#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh <version>   e.g. 0.5.0}"
TAG="v${VERSION}"

# Чистое рабочее дерево
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Есть незакоммиченные изменения — сначала закоммить" >&2
    exit 1
fi

# Только с main
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "Релизить только с main (сейчас: $BRANCH)" >&2
    exit 1
fi

# Тег не должен существовать
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Тег $TAG уже существует" >&2
    exit 1
fi

echo "Создаю тег $TAG..."
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo ""
echo "Тег $TAG запушен — GitHub Actions запустит сборку и создаст Release."
echo "https://github.com/froggychips/Froggy/releases/tag/$TAG"
