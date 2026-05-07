# Froggy build wrapper. Делает то же что `swift build`, плюс
# pre-build шаг компиляции `default.metallib` (см. ADR 0013).
# Без этого pre-build шага FroggyMLXWorker не может загрузить
# ни одной MLX-модели в release-сборке через SwiftPM.

.PHONY: build build-debug release test resolve metallib clean help

# Default target: release build.
build: release

release: metallib
	swift build -c release
	@mkdir -p .build/release/Resources
	@cp Sources/FroggyMLXWorker/Resources/default.metallib .build/release/Resources/default.metallib
	@echo "metallib placed at .build/release/Resources/default.metallib"

build-debug: metallib
	swift build
	@mkdir -p .build/debug/Resources
	@cp Sources/FroggyMLXWorker/Resources/default.metallib .build/debug/Resources/default.metallib
	@echo "metallib placed at .build/debug/Resources/default.metallib"

# Полный test run. Mlx-swift checkout нужен (`resolve` делает это).
test: resolve metallib
	@mkdir -p .build/debug/Resources
	@cp Sources/FroggyMLXWorker/Resources/default.metallib .build/debug/Resources/default.metallib 2>/dev/null || true
	swift test

# Только metallib. Idempotent, безопасно повторно.
metallib: resolve
	scripts/compile-metallib.sh

# Скачивает зависимости (включая mlx-swift checkout, нужный для metallib).
resolve:
	swift package resolve

clean:
	swift package clean
	rm -rf .build/metallib-work
	rm -f Sources/FroggyMLXWorker/Resources/default.metallib

help:
	@echo "make build         — release build + post-build metallib copy (default)"
	@echo "make build-debug   — debug build + post-build metallib copy"
	@echo "make test          — swift test (нужен metallib для MLX-смок-тестов)"
	@echo "make metallib      — только пересобрать default.metallib"
	@echo "make clean         — clean всё, включая metallib"
