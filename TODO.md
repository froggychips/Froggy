# Froggy TODO

Задачи, которые осознанно отложены — чтобы не делать «по пути увидел —
рефакторим». Если из этого списка что-то всплыло во время работы над
другой задачей, не трогаем здесь и сейчас.

## Code freeze (Sources/**)

Действует с 2026-05-09. Снимается при выполнении **одного** из условий:
* Успешный E2E тест аудио на реальном созвоне (Discord + mic, финальный
  транскрипт записан в markdown, `froggy recap` отдал summary).
* Или явное решение пользователя «снимаем freeze».

До снятия: CI/Makefile/docs/issues/tests через fake-worker — разрешены.

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

### Thaw latency: visible UX feedback (наблюдение 2026-05-09 live session)
Auto-thaw на frontmost-change (ADR-0015) **работает** — лог подтверждает
`frontmost activated mid-freeze: thawing pid=NNNNN` за 2 ms. Но
visible-to-user latency высокая: после `SIGCONT` heavy app (Telegram,
Electron-renderer, ~1 GB резидента, частично в swap) **нужно 1–2 s на
repaint**. Юзер видит «не реагирует», предполагает что app сломан, не
понимает что происходит.

Возможные направления (от дешёвого к сложному):

* **Visual feedback в MenuBar.** Toast / status-line «Telegram
  размораживается…» при auto-thaw. Юзер видит что что-то делается.
  ~1 час.
* **Документация в README.** Честный disclaimer: «expect 1–2 s delay
  when re-activating an app frozen during sustained pressure». ~10 мин.
* **Pre-emptive thaw on intent signals.** Слушать события до
  `didActivateApplication` (cmd-tab началась, mouse down on dock).
  Проблема: нет публичного API на dock click, CGS private — TCC и
  stability tradeoff. Не v1.0.
* **Force-pagein после `SIGCONT`.** Aggressively read pages из swap
  обратно в RAM до того, как юзер ждёт. Не уверен, есть ли публичный
  API. Не v1.0.

**v1.0 scope:** только первые два — visual feedback + README disclaimer.
ADR-кандидат: «User-perceived thaw latency: feedback + documented
expectation».

### Snapshots = bounded window, не lifetime counter (наблюдение 2026-05-09)
В `froggy status` поле `snapshots` показывает текущий размер
context-store'а. Capacity = 30. Поведение в реальном запуске:
ramp-up 0 → 12 → 18 → 30 за время load + gen, дальше **плато на 30**
35+ минут, даже при активном переключении окон.

**Симптом:** выглядит как «застрявший счётчик» при быстром взгляде на
status. Реально — нормальная bounded-queue dynamics, новые OCR
вытесняют старые.

**Структурная проблема, не косметика:**
* Window 30 × 2 s = **60 s history**.
* `gen --context` суёт в prompt **все 30** кадров.
* Если экран изменился 30 s назад, half of context — устаревшая.
* Модель отвечает не «что на экране **сейчас**», а «что было за
  последнюю минуту суммарно». Это и есть source of hallucinations,
  замеченных в утренней live-сессии (упоминание «CronJob» которого
  на экране в момент запроса не было).

**v1.0 scope (минимум):**
* Сделать видимым в `froggy status`: `snapshots 30/30 (window-cap)`
  или `snapshots 30 (last 60s)` вместо просто `30`.
* README disclaimer: «context is last-60-seconds, not current frame».

**Не v1.0, в v1.1:**
* Recency-weighted ranking в context'е (свежий кадр > старый).
  Похоже на Mem-5 этап 2 ranking-overlay по форме, но другая
  поверхность (OCR context, не freeze ranking).
* Frame-diff aware dedup: 5 идентичных кадров подряд → 1 entry с
  timestamp-range. Освобождает window под разнообразную историю.

## Этап 1 не сделан в этой сессии
**`/froggy-bench --save` × 3 сценария** (idle / model-loaded /
under-pressure) — gate из плана. Я не могу запустить полноценный
benchmark без живого FroggyDaemon + загруженной модели + реальных
frontmost-приложений. Делается пользователем после merge всех Mem-серии,
до того как браться за overlay (Mem-5 этап 2) или Уровень 2.

## Trust Governance — следующий шаг после AD-1 + FCP-1 + EXP-1 (не Уровень 2)

После того как AD-1 / FCP-1 / EXP-1 смерджены — **не открывать Уровень 2**
напрямую. Сначала замкнуть trust governance (Уровень 1.5 продолжение):

### AD-2 — audio + camera freeze signals

Источник: [`docs/design/activity-detection.md`](design/activity-detection.md) § AD-2.
Самый важный trust-governance gap: Froggy умеет не морозить frontmost-app
(AD-1), но не знает когда процесс ведёт активный аудио-звонок или видео.
Failure mode: **заморожен Zoom/Discord mid-call → аудио обрывается → uninstall.**
THESIS называет это thesis-level failure, не баг.

Что реализовать:
* `CoreAudio HAL` query: `kAudioDevicePropertyDeviceIsRunning` по pid'у кандидата.
  Если процесс держит активный I/O stream → confidence 0.9 → не морозить.
* `CoreMediaIO HAL` query для камеры (аналогично). Confidence 0.95.
* Интеграция в `VortexCoordinator.freezeTier()`: перед SIGSTOP — запрос
  ActivityDetector, skip если confidence > threshold.
* 50 ms timeout на HAL queries (уже описан в design-doc), fallback = 0 (нейтрально).
* Тесты: `FakeActivityDetector` (по аналогии `FakeMemoryPressureSource`).

ADR обязателен (новый сигнал, расширение threat model). Ref:
[`docs/design/activity-detection.md`](design/activity-detection.md).

### QW-0 — Calendar accessor (EventKit) (после снятия freeze Sources/**)

`CalendarAccessor` в `LushaExperimental`. EventKit → текущие и ближайшие
события из Calendar.app: название, участники, время, описание. Отдаётся в
контекст LLM перед созвоном — модель знает тему и участников.
Entitlement: `NSCalendarsUsageDescription`.

Синергия с аудио: если `listen` запущен и есть активное событие — его
summary автоматически добавляется в начало transcript-файла сессии.
~40 строк accessor + plist. Ref: Grok review 2026-05-09 (Calendar accessor).

### QW-1 — URL-accessor (Apple Events) (после снятия freeze Sources/**)

Новый `BrowserURLAccessor` в `LushaExperimental`. Apple Events → активная вкладка
Safari / Chrome / Arc / Brave → URL + title. Entitlement:
`com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription`.
~30 строк accessor + plist-правка. Без этого LLM видит OCR-текст страницы, но
не знает адрес — разница в качестве генерации значительная для «что за сайт?».

Ref: [`docs/peer-research/competitor-analysis.md`](peer-research/competitor-analysis.md) § QW-1.

### QW-2 — Incognito auto-pause (после снятия freeze Sources/**)

В `VisionActor` перед каждым capture-циклом — Apple Events → `AXIsPrivate`
активного браузерного окна. Если да → пропустить снапшот, не писать в
ContextStore. Privacy non-negotiable по THESIS. Тот же entitlement что QW-1 —
один PR с QW-1.

Ref: [`docs/peer-research/competitor-analysis.md`](peer-research/competitor-analysis.md) § QW-2.

---

## Уровень 2 — заблокирован до AD-1 + FCP-1 + EXP-1 в main

См. ADR 0011 (он же «ADR-0009» в внешних заметках). Не трогаем design,
не открываем target'ы под voice/VLM, пока Уровень 1.5 не в main:
* ROI OCR — запускать Vision только на изменившихся прямоугольниках,
  а не на всём кадре.
* Downscale в `SCStream` на стороне ядра (не в нашем CIContext).
* Electron soft-suspend через `AppleEventDescriptor` (без SIGSTOP).
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

## Mem-purgable-1 — purgable VM для own evictable caches (заблокирован до Уровня 1.5 в main)

Сейчас все наши allocations (`ContextStore` window snapshots,
`FrameDigest` history, Vision frame staging buffers, OCR result cache
если появится) — обычная anonymous-память. Под memory pressure'ом
kernel пишет их в compressor / swapfile вместе с остальными dirty
страницами. Это **избыточно**: для recoverable cache'й нам не нужен
round-trip через swap — мы пересчитаем содержимое при следующем
обращении.

`mach_vm_purgable_control(VM_PURGABLE_VOLATILE)` / Darwin-flavor
`madvise(MADV_FREE_REUSABLE)` дают точно то что нужно: помечаем регион
«можно дискардить без записи в swap», kernel под pressure'ом просто
zero-fill'ит страницы. Это **сильнее** PageoutChain'а для своих
данных — нет swap I/O вообще, нет SSD-износа, нет compressor-cycles.
Этот пункт **поглощает** ранее существовавший Уровень-2 entry «File
cache flush через `purgeable` API».

### Что добавить

* `PurgableBuffer<T>` actor / wrapper над VM-регионом с явным
  lifecycle:
  - `markVolatile()` → `mach_vm_purgable_control(VM_PURGABLE_VOLATILE)`.
  - `markNonVolatile() throws -> WasReclaimed` →
    `mach_vm_purgable_control(VM_PURGABLE_NONVOLATILE)`, проверка
    `state == VM_PURGABLE_EMPTY` (kernel дискардил регион).
  - `recompute` callback — что сделать если регион reclaim'нут.
    Обязательно фиксируется при создании буфера.
* Применить:
  - `LushaBridge/ContextStore` — sliding window snapshots помечать
    volatile между запросами; `recompute` = «нет данных, отдадим
    пустой блок».
  - `LushaBridge/FrameDigest` — history массив 32×32 fingerprint'ов
    помечать volatile; `recompute` = «считать дольше = wider similarity
    window после reclaim'а» (graceful degradation).
  - Vision frame staging buffers (если есть own staging вне Apple
    CVPixelBuffer pool'а) — `MADV_FREE_REUSABLE` между cycles.
* IPC `purgableStats` — кол-во reclaim-events за последний час, по
  типу буфера. Для honest validation эффекта.
* `NSCache`-альтернатива поверх purgable там, где это fits
  (key-value, не raw VM). NSCache внутри использует purgable +
  memory pressure subscription — меньше своего кода.
* ADR-XXXX — purgable VM architecture: где использовать, где **нельзя**
  (state buffers `MLXSupervisor`, `FrozenPidsStore`, `FreezeStatsStore`
  SQLite — non-volatile).

### Что переиспользуется

* `MemoryPressureMonitor` — не меняется, purgable работает автономно
  (kernel-driven, не наш code path).
* IPC/MenuBar — добавить `purgableStats` команду + панель «reclaims/h
  by buffer type».

### Honest caveats — обязательная часть ADR

* **Не drop-in replacement обычной памяти.** Каждый read-of-volatile
  требует `markNonVolatile() → check state → if empty: recompute`. Это
  +код и +cognitive load на каждом call-site. Применять только где
  recompute разумный (cache, snapshots), **не** для state.
* **Bug class «used-after-reclaim».** Если забыли `markNonVolatile()`
  перед чтением — undefined behavior. Тип-системой Swift полностью не
  закрыть; нужны runtime asserts + тесты на artificially-pressure'd
  scenarios.
* **Granularity.** `mach_vm_purgable_control` работает на VM-region,
  не per-byte. Минимальный размер ~1 page (16 KB ARM64). Маленькие
  cache'и (десятки байт) — не подходят, overhead > savings.
* **Win при низком pressure'е стремится к нулю.** На 16+ GB Mac'е без
  давления kernel держит volatile регионы как обычные — никакого
  reclaim'а, и тогда purgable-обвес — мёртвый код. Это
  **substrate-feature для 8 GB**, не universal optimization. ADR
  должен это явно зафиксировать.
* **Тесты artificially-pressure'd обязательны.** Нужны xctest'ы
  умеющие провоцировать reclaim — комбинация `scratch` стратегии
  PageoutChain'а + `FakeMemoryPressureSource(.critical)` + проверка
  что reclaim случился. Без таких тестов мы не знаем, работает ли оно
  вообще.

### Validation gate

Прежде чем имплементировать — снять `bench/purgable-baseline.json`:

* Сколько MB занимают `ContextStore` window + `FrameDigest` history
  + frame staging в типичной сессии.
* Под under-pressure scenario из ADR-0011 — сколько из этого ушло в
  compressor / swapfile **без** purgable (по `proc_pid_rusage` deltas).
* Сколько ушло бы в purgable-mode (моделируется через ручной
  `markVolatile` всех кандидатов + наблюдение reclaim-event'ов).

Если потенциальный saving < 50 MB на типичный 8 GB сценарий —
**остановиться**, документировать null result, не имплементировать.
Тот же honest-stop, что и для memory / power / jetsam baseline.

### Не сейчас

Заблокирован до AD-1 / FCP-1 / EXP-1 в main (Уровень 1.5). Идёт
параллельно Power-1 / Obs-1 / Уровню 2 — порядок по приоритетам.

## MLX-LM-1 — inference config + advanced features audit (заблокирован до Уровня 1.5 в main)

Сейчас MLX-инференс работает на defaults: что-то заводское из
`mlx-swift-lm`, без явной экспозиции sampling параметров в IPC, без
проверки enabled-by-default ли flash-attention в нашей версии, без
оценки speculative decoding ROI на 8 GB. Generation-quality wins
лежат **внутри** текущего MLX-пути, не требуют архитектурных
изменений — но требуют audit'а и явной конфигурации.

### Что добавить

* **Sampling parameters в IPC `generate`** — `temperature`, `top_p`,
  `top_k`, `min_p`, `repetition_penalty`. Сейчас, скорее всего,
  defaults (проверить). Exposed через `generationDefaults` в config
  + per-request override через IPC.
* **Flash attention status check.** Проверить enabled-by-default в
  текущей mlx-swift или нужен явный флаг. Уменьшает память на
  длинных context'ах — критично для context-aware режима с большим
  OCR window.
* **`MLX.Memory.reclaim()`** если доступен в текущей mlx-swift —
  более агрессивно возвращает память system'у, чем `clearCache()`.
  Использовать в `unloadModel` parallel-fallback'ом.
* **Chat template integration test.** Сейчас auto-detect от
  HuggingFace tokenizer. Зафиксировать xctest, что для текущей
  модели (Qwen3-4B) prompt format корректен. При смене модели —
  тест ловит формат-несоответствие до того как silently degraded
  generation попадает в prod.
* **Speculative decoding ROI assessment.** Draft model + verifier =
  ~1.5-2x speedup, но требует ~0.5B draft = +0.3-0.5 GB RAM.
  На 8 GB margin — оценить, влезает ли через validation-gate-style
  cycle (load draft + main + наблюдать `worker_rss_kb` distribution).
* IPC `generationConfig` get/set команды — runtime introspection.
* MenuBar — отдельная debug-панель «sampling controls» для
  exploration, не daily UX.

### Что переиспользуется

* `FroggyMLXWorker` IPC protocol — расширить generation-параметрами
  (backward-compatible через optional fields).
* `MLXSupervisor` — без изменений, прокидывает новые args в worker.

### Honest caveats

* **Это hygiene, не feature.** Audit current MLX path — может
  закончиться null result'ом «defaults уже хорошие, нечего
  улучшать», и это **успешный** outcome, не провал.
* **Speculative decoding на 8 GB — узкий margin.** Если draft
  модель не помещается рядом с main — отвергаем, документируем,
  не имплементируем. Honest-stop по той же логике что Power-1 /
  Obs-1 / Mem-purgable-1.
* **Sampling tweakability — risk for users.** Exposed parameters
  легко настроить плохо (high temp + high top_k = хаос). Defaults
  должны оставаться разумными; tweakability — для exploration, не
  daily user knob.

### Validation gate

Прежде чем имплементировать — снять `bench/inference-baseline.json`:

* Tokens/sec на defaults для текущей модели (idle / model-loaded
  scenarios из ADR-0011).
* Memory headroom на текущей модели (`worker_rss_kb` запас под
  draft).
* Honest answer: «есть ли вообще что улучшать?». Если defaults
  дают acceptable tok/s — sampling-exposure единственный win,
  остальное skipped.

### Не сейчас

Заблокирован до AD-1 / FCP-1 / EXP-1 в main (Уровень 1.5). Идёт
параллельно Power-1 / Obs-1 / Mem-purgable-1 / Уровню 2.

## RFC-Foundation-Models-Path — explore перед стартом Уровня 2 design (не сейчас)

**Не TODO-эпик, а закладка для архитектурного решения.** Между
закрытием Уровня 1.5 и стартом первого design-doc'а Уровня 2 —
обязательная exploration-фаза: что из Уровня 2 покрывается Apple
`FoundationModels` framework (macOS 26+, M-series, Apple
Intelligence-enabled) и что остаётся MLX-only.

`FoundationModels` даёт on-device LLM (~3B) с structured output,
tool-calling, streaming, без сети:

```swift
import FoundationModels
let session = LanguageModelSession()
let response = try await session.respond(to: prompt)
```

Это **второй inference-путь**, не drop-in замена MLX:

* **Покрывает**: chat-LLM common case, 8 GB-friendly by Apple's
  design, managed weights/quantization, ANE-acceleration где
  возможно.
* **Не покрывает**: custom модели (Qwen / Llama / fine-tuned),
  KV-cache control, speculative decoding, sampling tunability,
  машины без Apple Intelligence enabled.

**Важно для audio pipeline:** тот же вопрос стоит и про Speech:
заменит ли Apple Speech framework из macOS 26 нашу связку
SFSpeechRecognizer (Phase 1) / WhisperMLX (Phase 3)? Exploration
должен ответить и на это — не только «заменит ли MLX для chat».

### Что должно быть в exploration

* Что из Уровня 2 (voice / VLM / persona-router) **уже** есть у
  Apple на FoundationModels-стеке: Speech, on-device
  vision-language, system-level. Устаревает ли наша роадмапа
  перед стартом design'а?
* Что из substrate'а Froggy остаётся релевантным:
  - **Memory management фоновых apps** — да, не зависит от
    inference path.
  - **Subprocess isolation MLX (ADR-0008)** — становится
    опциональным для FoundationModels-пути (Apple internally
    управляет RAM).
  - **Vision OCR + Redactor + ContextStore** — да, не зависят.
  - **PageoutChain, FreezeRanker, FreezeStatsStore** — да, не
    зависят от LLM-стека.
* Возможные исходы (фиксируется в ADR):
  - **A**. FoundationModels primary, MLX fallback для custom
    моделей. Substrate упрощается на common case.
  - **B**. MLX primary, FoundationModels не используем (слишком
    ограничен / нужен полный контроль). Substrate как сейчас.
  - **C**. Hybrid orchestrator с runtime routing. Сложнее, оба
    мира, оба code path'а maintain'ятся.

### Почему не сейчас

ADR-0014 запрещает Уровень-2 design до закрытия Уровня 1.5. Этот
RFC — **между** ними, не вместо них и не блокирует AD-1/FCP-1/EXP-1.
Просто закладка чтобы через год не обнаружить, что substrate-cycles
тратились на проблему, которую Apple предоставила бесплатно. ADR
обязателен на любом исходе exploration'а.

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
* **`VNGenerateImageFeaturePrintRequest` как замена `FrameDigest`.**
  Apple-blessed perceptual hash (768-dim feature vector) учитывает
  семантику кадра, не pixel similarity — меньше false-positive
  (смена color theme), меньше false-negative (контент тот же,
  передвинут). Стоимость: тяжелее посчитать, но кэшируется. При
  следующем касании FrameDigest — рассмотреть как замену через
  bench (similarity-quality + compute cost).
* **`VNClassifyImageRequest` как pre-OCR router.** ~1000 labels per
  frame ("text", "code editor", "video", "game"). Дешёвый router:
  если frame классифицируется как «video» — OCR не запускается,
  context update пропускается. CPU-win + signal-quality (нет
  бессмысленного OCR на видео-плеере). Promising для FCP-1
  contention'а frame-budget'а.

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

### Shell completions для froggy CLI (после снятия freeze Sources/**)

`bash` / `zsh` / `fish` completions для всех команд froggy. Генерируется
через `ArgumentParser` если перейдём на него, иначе руками в
`Sources/FroggyCLI/Completions/`. ~50 строк, нулевые зависимости.

## Меньшие хвосты
* `/security-review` на Mem-5 (SQLite + телеметрия) — формально
  пропущен в автономном режиме. ADR 0010 содержит security-секцию
  ручной аудит, но прогон через skill — на следующую сессию.
* `/simplify` на `MLXSupervisor.swift` + `FroggyMLXWorker/main.swift`
  после Worktree A — проверить, не подросло ли там лишнее с момента
  Mem-3.
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
* **Mach exception ports для self-crash forensics.** Когда сам
  `FroggyDaemon` падает (assertion failure, EXC_BAD_ACCESS), сейчас
  у нас нет stack trace'а — kernel шлёт SIGKILL и тишина. Установить
  `task_set_exception_ports(EXC_MASK_ALL, ...)` + thread читает
  exception messages, дампит stack в `os.Logger` с
  `privacy: .private`, потом re-raise. Niche reliability, но
  combined с `make logbundle` — лучшая forensics на user-machine.
* **`os_proc_available_memory()` в `VortexActor`.** Apple API,
  возвращает доступный memory budget для текущего процесса.
  Дополняет `host_statistics64(HOST_VM_INFO64)` собственным
  «сколько мне осталось», без пересчёта через free-pages вручную.
  Маленький helper, hygiene.
* **`actions/checkout@v4` Node.js 20 deprecation.** Self-hosted CI
  warning'ит про deprecation в сентябре 2026. Обновить до v5+
  (когда выйдет) или установить env flag
  `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` в workflow. Не error —
  просто warning, не блокирует, но к Q3 2026 надо закрыть.

## Peer research — cherry-pick кандидаты

* **MLX-перф из Klee** (частично done):
  - ✅ KLEE-A: Metal warmup после loadModel
  - ✅ KLEE-B: `Memory.cacheLimit = recommended * 0.75`
  - ✅ KLEE-C: проверен, defaults уже корректны (prefillStepSize=512, topP=1.0)
  - ✅ KLEE-F: `GenerateCompletionInfo` метрики в done-event + bench fix
  - ⬜ `ModelConfiguration(directory:)` вместо URL — после снятия freeze
  - ⬜ `TokenizerPatcher` — после снятия freeze
  Ref: [`docs/peer-research/klee-mlx-optimizations.md`](docs/peer-research/klee-mlx-optimizations.md).

* **Competitor analysis (Memento / Klee / ChatMLX):** см.
  [`docs/peer-research/competitor-analysis.md`](docs/peer-research/competitor-analysis.md).
  Где Froggy опережает (memory orchestration, subprocess isolation, redaction,
  scriptability), где отстаёт (URL-контекст, incognito-пауза), что не делает
  никто (audio + screen → LLM на 8 GB, tool calling над screen context).
  Явные non-goals зафиксированы там же: persistent history / SQLite FTS5,
  signed DMG как user-feature, semantic search — всё это POSITIONING non-goal.
  **COMPETITOR-KLEE-TOOLCALL** — mlx-swift-lm ToolCall API референс для
  design Уровня 2 (tool calling).

## Боевой toolset (meeting transcription)

* **Design doc:** [`docs/design/meeting-transcription.md`](docs/design/meeting-transcription.md).
  Discord audio + микрофон → WhisperMLX (preview малой моделью + finalize
  large-v3) → markdown + LLM summary через `FroggyMLXWorker` + Jira draft
  через Atlassian MCP. Hybrid realtime/batch, MVP без diarization.

**Статус по фазам:**

* ✅ **Phase 1** — CATap + AVAudioEngine + SFSpeechRecognizer + IPC
  (`listen` / `listen-stop` / `listen-stream` / `listen-status`)
* ✅ **Phase 2** — VAD gate, echo suppression, SessionStore markdown,
  `froggy recap` (on-demand LLM summary, streaming)
* ⬜ **Phase 3** — WhisperMLX замена SFSpeechRecognizer. Блокируется
  audit'ом `froggychips/interview-assistant`: выяснить почему CATap
  был отброшен в том прототипе, чтобы не унаследовать блокер.
  После снятия code freeze на `Sources/`.
* ⬜ **Phase 4** — Jira task auto-detection во время созвона +
  Atlassian MCP `createJiraIssue` / `addCommentToJiraIssue` из summary.

* **Prior art:** [`froggychips/interview-assistant`](https://github.com/froggychips/interview-assistant) —
  production-grade audio capture + WhisperMLX. Phase 3 не стартовать
  без его audit'а.