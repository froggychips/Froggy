# Froggy build wrapper. Делает то же что `swift build`, плюс
# pre-build шаг компиляции `default.metallib` (см. ADR 0013).
# Без этого pre-build шага FroggyMLXWorker не может загрузить
# ни одной MLX-модели в release-сборке через SwiftPM.

.PHONY: build build-debug release smoke test full resolve metallib logbundle session-summary release-tag clean help

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

# Тиры тестов. Pre-commit / fast-feedback гонит smoke; CI default — test;
# full добавляет bench/ для редких pre-release прогонов.
#
# smoke — только pure unit'ы (~секунды). Без metallib, без сборки
# FroggyMLXWorkerFake. Пропускаем integration-тесты supervisor↔worker
# (требуют скомпилированный fake), metallib-presence (требует pre-build),
# и pageout-бенчмарк (медленный).
smoke: resolve
	swift test \
	    --skip MLXSupervisorIntegrationTests \
	    --skip MLXWorkerMetallibPresenceTests \
	    --skip PageoutBenchmarkTests

# Полный test run. Mlx-swift checkout нужен (`resolve` делает это).
test: resolve metallib
	@mkdir -p .build/debug/Resources
	@cp Sources/FroggyMLXWorker/Resources/default.metallib .build/debug/Resources/default.metallib 2>/dev/null || true
	swift test

# test + bench/. bench/run.sh держит свой baseline.json, см. bench/README.md.
full: test
	cd bench && ./run.sh

# Только metallib. Idempotent, безопасно повторно.
metallib: resolve
	scripts/compile-metallib.sh

# Скачивает зависимости (включая mlx-swift checkout, нужный для metallib).
resolve:
	swift package resolve

# Собирает unified-log архив для bug-report'а. Передавать аргументы в
# make неудобно (они интерпретируются как targets), поэтому здесь
# вызов «по дефолту» — `./froggy.logarchive` на весь boot. Для
# `--last 1h` или `-o <path>` запускать `scripts/logbundle.sh` напрямую.
logbundle:
	scripts/logbundle.sh

# Собирает session-summary bundle (log + SQLite freeze events + state +
# IPC snapshots + bench + notes template) для post-session анализа.
# Дефолт — `--last 1h`. Для другого периода или директории — запускать
# `scripts/session-summary.sh` напрямую.
session-summary:
	scripts/session-summary.sh

release-tag:
	@test -n "$(VERSION)" || { echo "Usage: make release-tag VERSION=x.y.z"; exit 1; }
	scripts/release.sh "$(VERSION)"

clean:
	swift package clean
	rm -rf .build/metallib-work
	rm -f Sources/FroggyMLXWorker/Resources/default.metallib

help:
	@echo "make build         — release build + post-build metallib copy (default)"
	@echo "make build-debug   — debug build + post-build metallib copy"
	@echo "make smoke         — быстрые unit'ы (~секунды), без metallib/integration"
	@echo "make test          — swift test (нужен metallib для MLX-смок-тестов)"
	@echo "make full          — test + bench/run.sh"
	@echo "make metallib      — только пересобрать default.metallib"
	@echo "make logbundle     — собрать froggy.logarchive для bug-report'а"
	@echo "make session-summary — собрать session-bundle (log+SQLite+state+IPC+notes)"
	@echo "make release-tag VERSION=x.y.z — тегировать и пушить; CI собирёт и создаст Release"
	@echo "make clean         — clean всё, включая metallib"
