# Froggy TODO

Задачи, которые осознанно отложены — чтобы не делать «по пути увидел —
рефакторим». Если из этого списка что-то всплыло во время работы над
другой задачей, не трогаем здесь и сейчас.

## Validation gate (блокирует всё)

**Прежде чем браться за AD-1 / FCP-1 / EXP-1 / Уровень 2 — снять
baseline.** См. ADR 0011.

```sh
/froggy-bench --save  # idle
# загрузить модель
/froggy-bench --save  # model-loaded
# открыть YouTube + Xcode build чтобы поймать .warning/.critical
/froggy-bench --save  # under-pressure
git add bench/baseline.json && git commit -m "bench: baseline до Уровня 1.5"
```

После — прочитать цифры honest. Если pageout-counters показывают
`succeeded = 0` под jetsam, или `secondsInLevel`-распределение под
реальной нагрузкой не выходит за `.normal` ни разу — **остановиться
и разобраться с substrate**, не идти дальше.

## Долги, идущие следом

### Mem-3.1 + Mem-4 (Worktree A) — закрыто (#26)

### Mem-3.1 + Mem-4 (Worktree A) — было

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

### Metallib regression — закрыто (ADR 0013 → Resolved)

Path 1 реализован: `scripts/compile-metallib.sh` + Makefile + post-build
copy в `.build/<config>/Resources/default.metallib`. `make build` —
канонический entry point. `bench/cycles_test.sh` 5/5 циклов load/unload
прошёл, `worker_rss_kb=null` после каждого unload, daemon не падает.
ADR 0011 validation gate закрыт 4/4.

### Уровень 1.5 (validation gate закрыт — можно стартовать)

Когда `bench/baseline.json` в main, model-loaded snapshot захвачен,
и цифры разумны:

* **AD-1 — frontmost-veto.** `VortexCoordinator` не морозит pid
  frontmost-app, даже если bundleId в `freezeTier1BundleIds`. Закрывает
  embarassing failure mode «freeze посередине набора текста».
* **FCP-1 — frame-cycle pacing.** `VisionActor` отбрасывает frame'ы из
  `SCStream`, пришедшие раньше `1 / captureIntervalSeconds`. Сейчас
  pacing внешний (Task.sleep между cycles); нужен внутренний.
* **EXP-1 — experimental accessors.** Отдельный target/протокол, в
  котором регистрируется аксессор с маркером `experimental: true` без
  правки `main.swift`. Отдельная IPC-команда.

Все три — маленькие PR. После их merge'a в main — **только тогда**
открывается дизайн-этап Уровня 2 (см. ADR 0011).

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

## Уровень 2 — заблокирован до AD-1 + FCP-1 + EXP-1 в main

См. ADR 0011 (он же «ADR-0009» в внешних заметках). Не трогаем design,
не открываем target'ы под voice/VLM, пока Уровень 1.5 не в main:
* ROI OCR — запускать Vision только на изменившихся прямоугольниках,
  а не на всём кадре.
* Downscale в `SCStream` на стороне ядра (не в нашем CIContext).
* Electron soft-suspend через `AppleEventDescriptor` (без SIGSTOP).
* File cache flush через `purgeable` API.
* Child-process для OCR (отдельный crash-domain как Mem-3 для MLX).
* Persona-router (несколько LLM с разными промтами/моделями).
* Voice (Whisper + TTS, OpenAI Realtime).
* Takeout-ingest (загрузка экспортов из других сервисов в context store).

## Зерна из external review (Grok, 2026-05-07)

Из проходного внешнего review-цикла — то, что не нарушает ADR-0011 и
имеет смысл записать как deferred items, чтобы не забыть к моменту
соответствующих фаз:

* **VortexCoordinator responsibility split.** Coordinator всё больше
  становится single-point-of-failure: pressure events, freeze
  decisions, model lifecycle, accessor invocations — всё через него.
  При следующем существенном касании Coordinator'а (например, при
  имплементации FCP-1) — рассмотреть выделение отдельных actor'ов
  вместо ещё одной ответственности на Coordinator. **Не сейчас**, не
  делать ради рефакторинга — gravity trap warning.
* **Pressure-aware model swap pattern.** Когда дойдёт до VLM/Whisper
  design — VortexCore должен решать, что выгрузить (chat LLM ↔ VLM ↔
  Whisper) под memory pressure, а не держать всё одновременно. Это не
  «slot manager», это reactive swap по той же логике что
  `MemoryPressureMonitor`. Закладывать в design-doc следующего слоя,
  не сейчас.
* **VLM layout analysis через VNDetect*.** При переходе к structured
  context (`VNDetectRectangles`, `VNDetectTextRectangles`) —
  рассмотреть как fallback или дополнение к текстовому OCR до того,
  как подключится full VLM. Промежуточная ступень между «плоский
  OCR» и «полная VLM», возможно более уместная для 8 GB.
* **Apple Speech как TTS-fallback** для voice-режима, помимо Piper.
  Бесплатное по RAM, низкого качества — но как graceful degradation
  под critical pressure (когда даже Piper нельзя загрузить) разумная
  опция. В voice design-doc когда дойдёт.
* **«Hey Froggy» wake word — privacy/battery review prerequisite.**
  Always-listening на 8 GB Mac имеет огромный privacy + battery
  surface area. Не делать без отдельного ADR, расширяющего threat
  model в `SECURITY.md`. Push-to-talk hotkey проще и безопаснее по
  умолчанию.

## Долг ADR-нумерации

* **Дубликат `0009-design-docs-after-implementation.md`** в
  `docs/adr/`. Содержание идентично 0011 (см. примечание о нумерации
  в 0011). При следующем касании ADR-инфраструктуры — удалить
  дубликат, обновить cross-reference в `THESIS.md` с 0009 на 0011, в
  `CONTRIBUTING.md` тоже.

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
