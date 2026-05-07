# Froggy TODO

Задачи, которые осознанно отложены — чтобы не делать «по пути увидел —
рефакторим». Если из этого списка что-то всплыло во время работы над
другой задачей, не трогаем здесь и сейчас.

## Долги, идущие следом

### Mem-3.1 + Mem-4 (Worktree A)
* `phase-mem/A-worker-tests-kvcache` уже залит локально, но swift test
  на момент коммита Mem-5 завис на `testShutdownTimeoutForcesSIGKILL`
  с предыдущей buggy версией `unloadModel`. После убийства зависших
  процессов и pull свежего кода (включая fix `unloadModel` через
  polling `process.isRunning` вместо `withTaskGroup`+`AsyncThrowingStream`):
  - перезапустить `swift test --filter MLXSupervisorIntegrationTests`
  - убедиться, что 4 теста проходят, плюс все остальные 115+
  - запушить, открыть PR, мерджить
* Контракт PR'а: один общий — `Mem-3.1 fake worker + Mem-4 KV-cache`,
  как описано в новом плане Уровня 1.

### Mem-5 этап 2: ranking-overlay
Активировать через ~неделю после включения телеметрии у пользователя.
Когда наберётся ≥ 100 событий по нескольким bundle_id:
* `FreezeRanker.applyOverlayTo(_ tier1: inout, _ tier2: inout)` —
  bundle с медианой ≥ 500 MB → tier-1 (даже если в конфиге его нет);
  ≤ 200 MB → tier-2; recoveryMs > 2000 → понижение приоритета.
* `VortexCoordinator` спрашивает overlay перед `freezeTier(.tier1)`.
* IPC `freezeStats` — добавить флаг `overlayActive` в response.
* MenuBar — отдельная отладочная панель «top-10 freedBytes» через эту
  команду. Опциональная задача.
* Bundle-id парсинг через `CFBundleIdentifier` (сейчас «псевдо-id»
  по имени `.app`-каталога).

### Pipe-lifecycle тестирование supervisor: углублённое
В Mem-3.1 покрыли happy / shutdown timeout / crash mid-generate / rapid
loop. Не покрыто:
* concurrent generate'ов от разных клиентов через один supervisor.
* race condition между `unloadModel` и активным generate-stream'ом.
* RSS-leak верификация на 100+ циклах load/unload.

## Этап 1 не сделан в этой сессии
**`/froggy-bench --save` × 3 сценария** (idle / model-loaded /
under-pressure) — gate из плана. Я не могу запустить полноценный
benchmark без живого FroggyDaemon + загруженной модели + реальных
frontmost-приложений. Делается пользователем после merge всех Mem-серии,
до того как браться за overlay (Mem-5 этап 2) или Уровень 2.

## Уровень 2 (намеренно вне этой серии)
Не трогаем без отдельного запроса:
* ROI OCR — запускать Vision только на изменившихся прямоугольниках,
  а не на всём кадре.
* Downscale в `SCStream` на стороне ядра (не в нашем CIContext).
* Electron soft-suspend через `AppleEventDescriptor` (без SIGSTOP).
* File cache flush через `purgeable` API.
* Child-process для OCR (отдельный crash-domain как Mem-3 для MLX).
* Persona-router (несколько LLM с разными промтами/моделями).
* Voice (Whisper + TTS, OpenAI Realtime).
* Takeout-ingest (загрузка экспортов из других сервисов в context store).

## Меньшие хвосты
* `/security-review` на Mem-5 (SQLite + телеметрия) — формально
  пропущен в автономном режиме. ADR 0010 содержит security-секцию
  ручной аудит, но прогон через skill — на следующую сессию.
* `/simplify` на `MLXSupervisor.swift` + `FroggyMLXWorker/main.swift`
  после Worktree A — проверить, не подросло ли там лишнее с момента
  Mem-3.
* CI workflow на Froggy всё ещё `startup_failure` (account-level
  Actions activation у `froggychips`).
* Hooks из `phase-mem/00-infra` (PR #15) активируются только в
  следующей сессии Claude Code — текущая их не подхватит.
* Git committer email = `yaroslav@JabBook-Air-m3.local` (machine
  hostname) — `git config --global user.email …` со стороны пользователя.
