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
  embarassing failure mode «freeze посередине набора текста». В ADR
  AD-1 явно решить scope: **minimal** (только `NSWorkspace`
  frontmost-app + window-title) либо **extended** (+ Accessibility
  API: `AXFocusedUIElementAttribute` + `AXValueChangedNotification` →
  typing-veto). Extended даёт прямой signal «пользователь печатает»,
  но требует TCC Accessibility permission и расширения threat model
  в `SECURITY.md`.
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

## Power-1 — energy/thermal management (заблокирован до Уровня 1.5 в main)

Принцип тот же, что у memory pressure: kernel/system сигналит →
`PressureSource` → `VortexCoordinator` → SIGSTOP по tier'ам.
Архитектурный delta минимальный — переиспользуются `VortexFreezing`,
`FrozenPidsStore`, `ProcessClassifier`, `FreezeRanker`. ADR обязателен
(новый класс сигнала, аналог ADR-0006/0007 для memory).

### Сигналы (composite — единого `dispatch_source` под энергию нет)

* `ProcessInfo.thermalState` — `nominal/fair/serious/critical`,
  `NSProcessInfoThermalStateDidChangeNotification`. Реактивно, 4 ступеньки.
* `ProcessInfo.isLowPowerModeEnabled` +
  `NSProcessInfoPowerStateDidChangeNotification` — boolean user-toggle.
* IOKit `IOPSCopyPowerSourcesInfo` — on AC / на батарее, % charge,
  time-to-empty. Не реактивно, polling ~30s.
* `proc_pid_rusage` → `ri_energy` (RUSAGE_INFO_V4+) — нДж per-process.
  Counter, EWMA-окно за period; расширяется существующий
  `ProcessRusage.swift`.

Composite-уровень `.normal/.warning/.critical` собирается из
`thermalState` + `isLowPowerMode` + on-battery + battery%. Конкретный
маппинг — в ADR.

### Что добавить

* `PowerPressureSource` protocol + `DispatchPowerPressureSource` /
  `FakePowerPressureSource` (analog `MemoryPressureSource`).
* `PowerPressureMonitor` — composite signal aggregator + derived level.
* `ProcessRusage` — чтение `ri_energy`, EWMA per-pid за окно.
* Параллельный feedback-loop в `VortexCoordinator` либо общий с
  power-tier overlays поверх memory-tier.
* Конфиг: `freezePowerTier1BundleIds`, energy thresholds (Дж/с).
* ADR-XXXX — power-pressure architecture.

### Honest caveats — без этого не стартовать

* **Tier-листы RAM ≠ power.** Slack/Teams/Electron лёгкие по RAM,
  тяжёлые по wakeups. Либо разводить конфиг, либо overlay-policy
  в `FreezeRanker`.
* **Frontmost-app дороже всех фоновых вместе** при типичной нагрузке
  (браузер с видео). Реальный win Power-1 — на тепловом критикале и
  на конкретных misbehaving background apps; не «давайте экономить
  вообще».
* **macOS уже агрессивно гасит фон на batt** (App Nap, network
  throttling, process suspension). Дельта от SIGSTOP поверх этого —
  мерить на baseline ДО имплементации, не после.

### Validation gate (по аналогии с ADR-0011)

Прежде чем имплементировать — снять `bench/power-baseline.json`:

* Дж/мин типичного idle-фона на batt без Froggy.
* Дж/мин Slack/Teams/Electron-apps в фоне за час.
* `thermalState` distribution на типичной нагрузке (Xcode build +
  YouTube + Slack).
* `isLowPowerMode` events на реальном использовании за неделю.

Если фон даёт <5% energy share от total — **остановиться**,
документировать null result, не имплементировать. Тот же honest-stop
паттерн, что и для memory baseline.

### Не сейчас

Заблокирован до AD-1 / FCP-1 / EXP-1 в main (Уровень 1.5). Идёт
параллельно Уровню 2 — порядок по приоритетам, не строго.

## Obs-1 — Jetsam observer + unified log как honest signal (заблокирован до Уровня 1.5 в main)

Сейчас «работает ли freeze» решается косвенно: pageout counters,
`secondsInLevel`-distribution, RSS-замеры. Прямой сигнал — kernel сам
пишет jetsam-kill events в unified log (subsystem `com.apple.kernel`,
сообщения семейства `memorystatus_do_kill` / `jetsam`). Это закрывает
honest-signal gap из ADR-0011: было ли убийство OS-ом после наших
freeze'ов или нет. Не «pageouts были», а «никого не убили / убили X».

### Что добавить

* `JetsamObserver` actor — подписка на kernel jetsam events через
  один из:
  - `OSLogStore.local()` + `getEntries(at: position, matching: ...)`
    — Apple-blessed reader, sandboxing-config или entitlement.
  - `Process` → `log stream --predicate 'subsystem == "com.apple.kernel"
    AND eventMessage CONTAINS "memorystatus"'` — без entitlement,
    через подпроцесс. Pragmatic путь.
* `MXMetricManagerSubscriber` actor — Apple-blessed daily-aggregate
  source поверх `MXAppExitMetric` (macOS 14+,
  `cumulativeMemoryResourceLimitExitCount` = jetsam-killed). Без
  developer-mode private-data toggle, в отличие от log_stream — но
  daily delivery, не real-time. Это **complement, не замена**:
  log_stream — dev/baseline real-time signal (брит к kernel-формату),
  MetricKit — prod ground-truth с задержкой суток. Поток в ту же
  таблицу `jetsam_events` с маркером `source = log_stream | metrickit`.
* Парсер: PID, имя процесса (если не редактирован), reason (highwater
  / no-pages / vm-thrashing). Структурированный event в
  `FreezeStatsStore` — новая таблица `jetsam_events`.
* IPC `jetsamStats` — кол-во OS-kills с timestamp'ами, по bundle_id.
* MenuBar — отдельная панель «kills since Froggy started» как honest
  счётчик «защитили ли мы или нет».
* ADR-XXXX — observation-source architecture (read-only аналог
  `MemoryPressureSource` / `PowerPressureSource`).

### Что переиспользуется

* `FreezeStatsStore` (SQLite) — добавить таблицу.
* `ProcessClassifier` — маппинг PID/имя в bundle_id.
* IPC/MenuBar — добавить новые команды/панель.

### Honest caveats — обязательная часть ADR

* **Private-redaction в production.** В default-конфиге macOS многие
  jetsam-сообщения помечены `private`, и `log stream` отдаёт
  `<private>` вместо PID/имени. Лечится `sudo log config --mode
  "private_data:on"` (developer-mode):
  - **OK для dev/baseline** — у тебя developer-mode скорее всего on.
  - **Слепая зона у пользователя** — в prod без developer-mode мы
    видим только факт kill'а без имени процесса.
  - В ADR честно зафиксировать: Obs-1 — dev/honest-signal feature,
    не user-facing observability. Альтернатива на prod: `proc_listpids`
    polling до/после, или MetricKit `MXAppLaunchMetric` + exit
    reasons, или sysdiagnose-парсинг (overkill).
* **Brittleness формата.** Текст kernel-сообщений между релизами
  macOS может меняться. Predicate жёсткий (subsystem + eventMessage
  CONTAINS), плюс integration test на текущей версии. Каждый major
  macOS bump — пере-валидация.
* **Privacy hygiene на нашей стороне.** Перед включением jetsam log
  stream'а — пройти все `os_log` call-sites Froggy и проверить, что
  bundle_id / window-title помечены `privacy: .private`. Иначе мы
  льём пользовательские данные в system log одновременно с тем, как
  с него читаем. См. отдельный хвост.
* **Performance.** `log stream` без predicate жжёт CPU. Predicate
  обязателен и жёсткий. Подпроцесс `log` через `Process` — отдельный
  failure mode (если упадёт — observer слепнет, нужен restart по
  той же логике, что `MLXSupervisor`).

### Validation gate

Прежде чем имплементировать — снять `bench/jetsam-baseline.json`:

* Сколько jetsam-kills происходит за час при типичной нагрузке
  **БЕЗ** Froggy (under-pressure scenario из ADR-0011).
* Сколько при включённом Froggy на той же нагрузке.

Если delta = 0 — **остановиться**, документировать null result, не
имплементировать дальше observation infra (наблюдать-то нечего:
freeze работает идеально, kernel kills не доходит). Тот же
honest-stop паттерн, что и для memory/power baseline.

### Не сейчас

Заблокирован до AD-1 / FCP-1 / EXP-1 в main (Уровень 1.5). Идёт
параллельно Power-1 / Уровню 2 — порядок по приоритетам.

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

## Зерна из API-ресерча (macOS, 2026-05-07)

Из ресерча по unused/underused macOS API в проекте. Низкий приоритет
по сравнению с Power-1 / Obs-1 — записать чтобы не забыть к моменту
соответствующих фаз, не делать сейчас.

* **`NSCache` для vision/token caches.** NSCache evict'ит элементы
  под memory pressure (kernel signal, тот же что DispatchSource).
  Если появятся hand-rolled caches (frame buffers, tokenized prompts)
  — NSCache даёт reactive eviction бесплатно. Применять при следующем
  касании cache-кода, не специальным рефакторингом.
* **`SMAppService` — modern launchd registration.** Современный путь
  для регистрации launch agent / login item из приложения. Заменяет
  устаревшие `SMLoginItemSetEnabled` / ручной plist в LaunchAgents.
  Когда дойдёт до installation UX (`packaging/`), не раньше.
* **`UserNotifications` (`UNUserNotificationCenter`)** — surface
  critical state поверх MenuBar dot. ScreenCapture permission revoked
  → push «restore permission». Jetsam случился несмотря на Froggy →
  «we couldn't save app X». Отдельный feature-эпик по UX, не сейчас.
* **`NaturalLanguage` (`NLTagger` / `NLEmbedding`)** — extraction
  entities/topics из OCR'd text до отправки в LLM. Бесплатно по RAM
  (десятки MB), без entitlement, без сети. Для context store /
  prompt augmentation в Уровне 2 — сэкономит токены. Промежуточная
  ступень между OCR и LLM.
* **FSEvents (`FSEventStream`)** — реактивный watch directory'ев для
  config reload, model checkpoint changes, или user-data tracking
  для context store. Без polling. Низкий приоритет — нет конкретной
  задачи под него.

### Не для нас (зафиксировано чтобы не возвращаться)

* **EndpointSecurity (ESF).** System Extension entitlement →
  notarization-special, install-time UX «extension wants to see all
  events» — пугает, MDM-территория. Слишком тяжело для пользы;
  альтернативы (NSWorkspace + DispatchSource process events +
  log stream) покрывают наши кейсы.
* **Замена unix-socket IPC на XPC / Network framework.** ADR-0002
  уже выбрал unix-socket. Reopen только если конкретный security-bug
  всплывёт.
* **`CGEventTap` для keyboard activity detection.** Глобальный
  event-tap «слышит каждое нажатие» — privacy bomb. AX API +
  `AXValueChangedNotification` даёт ту же информацию, не читая
  каждый keystroke. Если AX мало — отдельный ADR с расширением
  threat model, не дефолт.
* **SwiftData / Core Data вместо SQLite3.** Replacing for
  replacement's sake; миграции уже описаны.

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
* **Privacy audit всех `os_log` call-sites.** Один проход grep'ом по
  `Sources/**/*.swift` — все ли строки с `bundleId` / `windowTitle` /
  user-data помечены `privacy: .private`. Иначе мы льём пользовательские
  данные в system log, читаемый локальными админами. Префикс к Obs-1:
  прежде чем читать unified log — перестать в него лить.
* **`make logbundle`.** Тривиальный shell-скрипт обёртка вокруг
  `log collect --predicate 'subsystem == "com.froggychips.froggy"'
  --output froggy.logarchive` — для bug reports от будущих внешних
  пользователей. Без entitlement'ов, без кода.
* **`NSWorkspace` notifications вместо polling в
  `NSWorkspaceProcessFinder`.** Сейчас polling `runningApplications`;
  заменить на подписку `didActivate` / `didDeactivate` /
  `didTerminate`. Termination — критично: когда замороженный pid
  убили извне, надо удалить из `FrozenPidsStore`, иначе хранится
  мусор. Также: `willSleep` / `didWake` для gating'а freeze'ов
  вокруг sleep cycle'а; `screensDidSleep`/`Wake` для SCStream
  lifecycle. Один маленький PR, zero entitlement.
* **`DispatchSource.makeProcessSource(.exit)` в `MLXSupervisor`.**
  Заменяет polling `process.isRunning` (см. Mem-3.1 fix-debt).
  Реактивный kernel signal на pid exit, закрывает race-условия
  между polling и реальным exit'ом. Применить также к watcher'ам
  frozen pid'ов там, где не покрывает NSWorkspace (non-app helpers,
  Electron renderers).
* **`OSSignposter` инструментация в hot paths.** Frame pipeline,
  freeze cycle, MLX lifecycle (load/unload/generate), IPC roundtrip.
  Делается **перед FCP-1** как dev-tool — Instruments → Points of
  Interest визуализирует frame-budget, OCR latency, freeze-cycle
  duration. Также для bench: `xctrace` profile вместо собственного
  timing-кода. Аккуратно в hot paths, не везде.
