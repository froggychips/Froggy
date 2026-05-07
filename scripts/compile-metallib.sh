#!/usr/bin/env bash
# Компилирует mlx-swift Metal-shader'ы в default.metallib и кладёт их в
# Sources/FroggyMLXWorker/Resources/, откуда SwiftPM подхватывает как
# resource. Закрывает регрессию ADR 0013: `swift build` не компилирует
# `.metal` файлы по умолчанию, и без metallib worker умирает на первой
# реальной MLX-операции с «Failed to load default metallib».
#
# Запускать перед `swift build`. `make build` делает это автоматически.
#
# Idempotent: пропускает компиляцию, если metallib свежее всех .metal
# исходников. Не требует Xcode-проекта, использует только `xcrun metal` /
# `xcrun metallib` из CommandLineTools.
#
# Why these particular flags / kernel list:
#  * Список из 9 kernel-файлов — точная копия `KERNEL_LIST` из
#    `mlx-swift/tools/fix-metal-includes.sh`. Это кернелы которые mlx-swift
#    ожидает увидеть в default.metallib (другие mlx-операции используют
#    JIT compile через MLXFastKernel и не нуждаются в pre-built metallib).
#  * `-x metal -std=metal3.1`: bf16.h использует native bfloat type из
#    Metal 3.1+. Без `-std=metal3.1` падает с «unknown type name 'bfloat'».
#  * `-fno-fast-math`: совпадает с upstream CMakeLists. fast-math
#    ломает correctness reductions / softmax. ADR-0013 § Path 1.
#  * `-Wno-c++17-extensions -Wno-c++20-extensions`: тоже из CMakeLists,
#    подавляют шумные warning'и в mlx kernel-сорсах.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MLX_METAL_DIR="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
RESOURCES_DIR="$ROOT/Sources/FroggyMLXWorker/Resources"
METALLIB_OUT="$RESOURCES_DIR/default.metallib"
WORK_DIR="$ROOT/.build/metallib-work"

# Тот же список что mlx-swift fix-metal-includes.sh — kernel'ы которые
# попадают в default.metallib. Изменения здесь возможны только синхронно
# с upstream KERNEL_LIST.
KERNELS=(
    arg_reduce.metal
    conv.metal
    gemv.metal
    layer_norm.metal
    random.metal
    rms_norm.metal
    rope.metal
    scaled_dot_product_attention.metal
    steel/attn/kernels/steel_attention.metal
)

# Проверка: mlx-swift checkout есть? Если нет — `swift package resolve`
# не запускался. Подсказать пользователю.
if [ ! -d "$MLX_METAL_DIR" ]; then
    cat >&2 <<EOF
ERROR: mlx-swift checkout not found at $MLX_METAL_DIR

Сначала запустите \`swift package resolve\` чтобы SwiftPM скачал
зависимости, потом повторите \`scripts/compile-metallib.sh\` (или \`make build\`).
EOF
    exit 1
fi

# Проверка xcrun metal: доступен?
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: \`xcrun -sdk macosx metal\` не работает.

Требуется установить Command Line Tools (\`xcode-select --install\`)
или Xcode целиком. Только тогда метал-компилятор доступен.
EOF
    exit 1
fi

mkdir -p "$RESOURCES_DIR" "$WORK_DIR"

# Idempotency: если metallib свежее всех .metal исходников + этого скрипта,
# пропускаем работу.
if [ -f "$METALLIB_OUT" ]; then
    needs_rebuild=0
    for kernel in "${KERNELS[@]}"; do
        src="$MLX_METAL_DIR/$kernel"
        if [ "$src" -nt "$METALLIB_OUT" ]; then
            needs_rebuild=1
            break
        fi
    done
    if [ "$0" -nt "$METALLIB_OUT" ]; then
        needs_rebuild=1
    fi
    if [ "$needs_rebuild" = "0" ]; then
        echo "metallib up-to-date: $METALLIB_OUT"
        exit 0
    fi
fi

echo "compiling 9 metal kernels..."

# Метал flags — те же что использует upstream CMake (см. mlx Source/Cmlx/mlx/
# mlx/backend/metal/kernels/CMakeLists.txt :: build_kernel_base).
METAL_FLAGS=(
    -x metal
    -std=metal3.1
    -O3
    -fno-fast-math
    -Wno-c++17-extensions
    -Wno-c++20-extensions
)

cd "$MLX_METAL_DIR"
rm -f "$WORK_DIR"/*.air

for kernel in "${KERNELS[@]}"; do
    out_name=$(echo "$kernel" | sed 's|/|_|g; s|\.metal$|.air|')
    out_path="$WORK_DIR/$out_name"
    if ! xcrun -sdk macosx metal "${METAL_FLAGS[@]}" -c "$kernel" -o "$out_path"; then
        echo "ERROR: compile failed for $kernel" >&2
        exit 1
    fi
done

echo "linking $WORK_DIR/*.air -> $METALLIB_OUT ..."
xcrun -sdk macosx metallib "$WORK_DIR"/*.air -o "$METALLIB_OUT"

size=$(stat -f%z "$METALLIB_OUT" 2>/dev/null || stat -c%s "$METALLIB_OUT" 2>/dev/null || echo "?")
echo "OK: $METALLIB_OUT ($size bytes)"
