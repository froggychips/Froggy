# Design — Meeting transcription (Discord + микрофон)

* **Статус:** Draft / sketch. Не принято, не реализовано.
* **Дата:** 2026-05-09
* **Связано с:** ADR 0008 (subprocess isolation), ADR 0011 (validation gate),
  ADR 0009 (kvBits — переиспользуем тот же IPC паттерн для Audio worker'а).
* **Ключевой prior art:**
  [`froggychips/interview-assistant`](https://github.com/froggychips/interview-assistant) —
  собственный «нерабочий, но концептуальный» прототип user'а. Содержит
  **production-grade audio capture pipeline и WhisperMLX-стек**, которые
  при переносе в Froggy дадут готовый skeleton, а не зелёное поле. См. отдельную
  секцию [«Reuse from interview-assistant»](#reuse-from-interview-assistant)
  ниже — она перевешивает многие пункты этого документа.

## Контекст и мотивация

Текущий Froggy решает узкую задачу — заморозка процессов под memory pressure.
Это работает, но в боевом дне user'а **не закрывает ни одной живой задачи**.
Нужен минимальный прикладной toolset поверх той же машины, который
использует уже подключённые ресурсы (mlx-swift LLM, MCP-каналы, Apple Silicon).

Первый прикладной use case:

> На Discord-созвонах задачи раздают голосом, потом дублируют в Jira текстом.
> Хочется чтобы Froggy сам слушал созвон, отделял **«я»** от **«Discord»**
> и выдавал пригодный для Jira текст.

## Scope MVP

* Capture двух аудио-потоков:
  * **mic** — собственный микрофон,
  * **discord** — output Discord-приложения как **один** поток (без
    разделения участников внутри).
* Транскрипция **гибридная:**
  * realtime preview во время созвона (быстрая модель, latency ≤5 с),
  * batch финал после окончания (`large-v3` или эквивалент).
* Output **тройной**:
  1. Markdown-файл с двумя дорожками + timestamps на диск.
  2. LLM-summary через **уже существующий** `FroggyMLXWorker`
     (action items, обещания, дедлайны).
  3. Авто-черновик в Jira через
     [`claude.ai_Atlassian` MCP](https://github.com/cloudflare/mcp-server-atlassian)
     (или `mcp__claude_ai_Atlassian__addCommentToJiraIssue` /
     `mcp__claude_ai_Atlassian__createJiraIssue`).

## Non-goals MVP

* **Acoustic diarization участников Discord.** Разделить «я vs они» — да;
  «коллега-А vs коллега-Б внутри Discord» — нет. Pyannote-стек добавляет
  100–200 MB модели и реальную точность 70–85 %; для первой итерации
  не окупается. Если потом окажется critical — добавим как
  отдельный модуль (см. roadmap).
* **Discord bot / Discord API.** Чистые per-user voice streams через
  bot-API — это другой stack (server-side права, OAuth, persistent bot
  instance). MVP остаётся local-only.
* **Параллельные созвоны.** Один listener в момент времени.

## Архитектура

```
FroggyDaemon
├── MLXSupervisor → FroggyMLXWorker          (LLM, текущий)
├── VortexCoordinator                        (freeze, текущий)
└── AudioListener (NEW)
    ├── CaptureCoordinator
    │   ├── mic stream    (AVAudioEngine)
    │   └── discord stream (SCK / Core Audio Tap)
    ├── TranscriberSupervisor
    │   └── FroggyAudioWorker (subprocess)   ← по тому же паттерну, что MLX
    │       ├── WhisperKit instance: small/base (preview)
    │       └── WhisperKit instance: large-v3   (finalize)
    ├── SessionStore (transcripts to disk)
    └── PostProcessor
        ├── → FroggyMLXWorker (summary)
        └── → Atlassian MCP (Jira draft)
```

**Почему worker subprocess.** Тот же аргумент что в
[ADR 0008 — MLX subprocess isolation](../adr/0008-mlx-subprocess-isolation.md):
WhisperKit грузит Core ML модель в unified memory. Когда созвон
закончился, модель надо суметь выгрузить полностью, не «приблизительно».
`FroggyAudioWorker` подчиняется тому же протоколу IPC что
`FroggyMLXWorker` — load / unload / kill — и `unloadModel` гарантирует
возврат памяти ядру через subprocess termination.

**Почему capture в `Daemon`, а transcribe в `Worker`.** Capture тонкий —
Core Audio + SCK API, минимальная RAM, лонг-living поток. Transcribe
тяжёлый — ML inference. Рассечение по «легковесное держит state, тяжёлое
живёт в killable subprocess» — повторяем уже работающий паттерн.

## Stack choices

### Audio capture

| Версия macOS | API | Заметки |
|---|---|---|
| 14.4+ | [Core Audio Tap (`CATapDescription`)](https://developer.apple.com/documentation/coreaudio/catapdescription) | Tap по `pid`/`bundleID`. Чистый, нативный, без virtual device. Требует Screen Recording permission (так Apple). |
| 13.0–14.3 | [`ScreenCaptureKit` audio](https://developer.apple.com/documentation/screencapturekit) с `SCContentFilter(.application:)` | Apple-recommended до Tap API. Тот же permission. |
| < 13 | (BlackHole / Loopback) | Не поддерживаем. Platform у Froggy — `.macOS(.v14)`, Tap уже актуален. |

Микрофон — обычный AVAudioEngine, никаких особенностей.

**Решение:** на старте — SCK как baseline (работает на всём 14+). Если
смогу подписаться корректно с Tap-entitlements — добавлю Tap fast-path.

### Транскрипция — WhisperMLX (не WhisperKit)

**Решение пересмотрено** после нахождения interview-assistant. Там user
уже использует **WhisperMLX** (Whisper через mlx-swift), а не WhisperKit.
Файлы [`WhisperMLX.swift` (57KB)](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLX.swift),
[`WhisperMLXProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLXProvider.swift),
[`WhisperProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperProvider.swift).

Аргументы за WhisperMLX:

1. **Одна ML-инфра.** У Froggy уже зависимость на `mlx-swift-lm` и `mlx-swift`
   через `FroggyMLXWorker`. WhisperMLX живёт в той же экосистеме —
   одна доменная модель Metal-shader'ов, один ADR 0013-style metallib pipeline,
   одна точка обновления версий.
2. **Прецедент в interview-assistant.** Код уже написан и работал у user'а
   на той же машине. WhisperKit пришлось бы заново тестировать на
   permissions / Core ML compile / model fetch.
3. **GPU arbitration.** interview-assistant имеет `GPUResourceManager` +
   «GPU lock arbitration (Whisper vs Qwen)» в `ConversationOrchestrator`.
   Если бы мы взяли WhisperKit — два разных GPU-lifecycle'а под одним
   unified memory, конкуренция труднее контролируется.

Альтернативы (рассмотрены, отброшены):

* **WhisperKit** — Apple Core ML stack, отдельный от mlx-swift. Хорош для
  greenfield-проекта (Klee бы взял), но у нас уже есть MLX-инвестиция.
* **whisper.cpp** — рабочая, но C++ wrapping'ом усложняет Swift 6 strict
  concurrency story.
* **Apple Speech (`SFSpeechRecognizer`)** — Apple-native, но cloud-fallback
  на старых моделях, и качество русского — заметно хуже Whisper.

### LLM summary

`FroggyMLXWorker` уже есть и грузит mlx-swift LLM. Дополнительной
зависимости не нужно — отправляем транскрипт через тот же IPC-канал
с системным промптом «выдели action items / обещания / дедлайны».

Промпт — отдельный файл `Sources/.../prompts/meeting-summary.txt`,
версионируемый (поправил промпт → отвалился bench → откат).

### Jira draft

Через
[`claude.ai_Atlassian` MCP](https://docs.atlassian.com/) — у user'а
подключен, виден в текущей сессии (`mcp__claude_ai_Atlassian__*` инструменты).

* `createJiraIssue` — если из созвона вышло «новое таска».
* `addCommentToJiraIssue` — если был upd по существующему таску
  (mapping встречи → issue нужен — см. open issues).

## Data flow

```
                  ┌──────── Discord ────┐
                  │                     │
                  ▼                     ▼
   ┌─[ AVAudioEngine ]────┐  ┌─[ SCK / Tap ]────┐
   │  mic PCM 16kHz mono  │  │ discord PCM 16k  │
   └─────────┬────────────┘  └────────┬─────────┘
             │                        │
             └─────────┬──────────────┘
                       ▼
        SessionStore (на диск, append-only WAV или Opus)
                       │
                       ├──── ring buffer 30s
                       │       │
                       │       ▼
                       │   FroggyAudioWorker
                       │   small/base WhisperKit
                       │   → preview text events (UI/menubar)
                       │
                       ▼   (after session ends)
                   FroggyAudioWorker
                   large-v3 WhisperKit
                   → finalize transcript (markdown)
                       │
                       ├── disk: ~/Documents/Froggy/Meetings/<ts>.md
                       ├── FroggyMLXWorker → summary.md (action items)
                       └── Atlassian MCP → Jira draft (issue / comment)
```

**Обоснование двойной транскрипции (preview + finalize).** Realtime
с `large-v3` на M3 не вытянет real-time factor с приемлемой latency;
`base` вытянет, но точность хуже (особенно для русско-английского
code-switching). Финальный пересбор `large` поверх записанного
WAV-файла после звонка — компенсация.

## Permissions story

Точный набор entitlements **известен** —
[`InterviewAssistant.entitlements`](https://github.com/froggychips/interview-assistant/blob/main/InterviewAssistant.entitlements):

```xml
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.device.speech-recognition</key><true/>
<key>com.apple.security.screen-capture</key><true/>
```

Применимо к Froggy as-is:

* **`screen-capture`** — для SCK audio Discord'а. Apple соединил audio-only
  capture со Screen Recording, поэтому permission запрашивается странный
  для пользователя. В UI надо объяснить.
* **`speech-recognition`** — нужен только если используем Apple Speech как
  fallback. Если только WhisperMLX → можно НЕ запрашивать.
* **`network.client`** — для Atlassian MCP / HF model download.
* **`files.user-selected.read-write`** — для save-as маркдаун-транскриптов.
* **Microphone** — отдельно через `NSMicrophoneUsageDescription` в Info.plist
  (это не entitlement). TCC-prompt на первом запуске.
* **(опц.) Core Audio Tap** — на macOS 14.4+ `CATapDescription` идёт
  под `screen-capture` тем же entitlement'ом, новый отдельный не нужен.

Code signing config в проекте сейчас — debug. Production-сборка с
этими entitlements потребует actual developer cert
(см. [ADR 0012 — signing constraints honest doc](../adr/0012-signing-constraints-honest-doc.md)).

## Open issues / решить до Phase 1

1. **Trigger.** Что включает listener?
   * Hotkey (toggle on/off).
   * Auto-detect Discord в frontmost / running apps + voice activity.
   * Menubar action.
   * CLI: `froggy listen --duration 1h`.
2. **Mapping звонок → Jira issue.** Откуда берём ID issue для comment'а?
   * Calendar invite (Google Calendar MCP уже есть в окружении —
     вытащить description / Jira link).
   * Manual: hotkey `cmd+J` → дёргается inline-prompt «Jira ID?».
   * LLM-derived: summary содержит явный referenсе.
3. **Privacy.** Транскрипты содержат всё что говорят коллеги.
   * Хранить локально, не синкать (CloudDrive отключить для каталога).
   * Опция «redact PII через LushaBridge `Redactor` перед summary».
4. **Storage budget.** Часовой созвон в Opus ≈ 30 MB, в WAV — 230 MB.
   Через месяц активного использования — до 30 GB. Нужен retention
   policy: «храним N дней» / «храним только summary, raw чистим».
5. **Confidentiality модели.** WhisperKit — local. LLM — local
   (`FroggyMLXWorker`). Jira MCP — это **внешний service call** через
   Atlassian. Содержимое summary улетает на их сервер. Если на
   созвонах есть NDA-контент — это надо явно сказать пользователю.

## Roadmap (фазами)

### Phase 0 — verify feasibility (без правки `Sources/`)

* Спайк не нужен из-за наличия [interview-assistant prior art](#reuse-from-interview-assistant) —
  user уже подтвердил feasibility на M-серии silicon'е. Заменяется на:
* **Audit-pass по interview-assistant**: прочитать `AudioService.swift`,
  `WhisperMLX.swift`, `ConversationOrchestrator.swift` целиком, выписать
  что переносим и что нет. Эта заметка ↓ — первый проход; нужен
  второй с конкретными line-references после снятия freeze'а.
* **Verify build status interview-assistant.** User сказал «нерабочий».
  Понять что именно не работает: build fail / runtime crash / privacy
  prompt не выдаётся / Whisper медленный. Без этого риск унаследовать
  ту же проблему.

### Phase 1 — capture + batch transcription (после снятия freeze'а)

* `AudioListener` actor в `VortexCore` (или новый module
  `LushaListener` рядом с `LushaBridge`).
* `FroggyAudioWorker` subprocess с одной WhisperKit-инстанцией.
* CLI-команда `froggy listen` → пишет на диск + транскрипт после.
* Markdown-файл на выходе. Пока без Jira / summary.

### Phase 2 — preview + summary

* Вторая WhisperKit-инстанция в worker'е для realtime preview.
* Интеграция с `FroggyMLXWorker` для summary.
* Menubar item с current state.

### Phase 3 — Jira integration

* Atlassian MCP вызов из Daemon (или из CLI скрипта).
* Mapping calendar → Jira (см. open issue 2).

### Phase 4 (опц.) — diarization

* pyannote или альтернативный local-diarization.
* Только если Phase 1–3 показали что без этого useful, и user
  сказал что хочет.

## Что точно не делаем

* Не качаем за пользователем модель в момент первой записи. Pre-cache
  в `~/.froggy/whisper-models/<id>/` через menubar `Download model`.
* Не запускаем listener автоматически без подтверждения пользователя.
  Privacy-боль слишком большая.
* Не делаем cloud upload audio. Никогда. Локально или никак.
* Не лезем в Discord process internals (memory inspection / pipe
  hooking). Только публичные macOS API.

---

## Reuse from interview-assistant

[`froggychips/interview-assistant`](https://github.com/froggychips/interview-assistant) —
SwiftUI app для live технических интервью, написанный user'ом как
концептуальный прототип. Помечен как «нерабочий», но содержит
полностью продуманную audio + transcription + LLM pipeline,
которая на 70-80% переиспользуема для Froggy meeting transcription.

**Ключевая выгода:** мы не строим audio capture с нуля. Берём
готовые компоненты, выкидываем то что специфично для interview
use case (overlay-okno подсказок, OCR кода-на-экране, intent detection
для interview-вопросов) — остаётся базовый pipeline, идеально
подходящий под наш use case.

### Что переносится почти as-is

| Файл из interview-assistant | Размер | Зачем нам |
|---|---|---|
| [`AudioService.swift`](https://github.com/froggychips/interview-assistant/blob/main/AudioService.swift) | 97 KB | **Главный приз.** Три стратегии capture: `processTap(pid:)` (Core Audio Tap), `loopback(deviceName:)` (BlackHole + aggregate), `microphoneOnly`/`appPreferredInput`. Watchdog для engine stall, fallback chains, signal telemetry, channel auto-detection. Production-grade. |
| [`WhisperMLX.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLX.swift) | 57 KB | MLX-based Whisper inference — наш STT engine. |
| [`WhisperMLXProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLXProvider.swift) | ~6 KB | Provider abstraction — позволяет менять backend без переписывания caller'ов. |
| [`VAD.swift`](https://github.com/froggychips/interview-assistant/blob/main/VAD.swift) + [`VADTests.swift`](https://github.com/froggychips/interview-assistant/blob/main/InterviewAssistantTests/VADTests.swift) | 4 KB + 9 KB | Voice activity detection — нужен чтобы не транскрибировать тишину. С тестами. |
| [`SpeechNormalizer.swift`](https://github.com/froggychips/interview-assistant/blob/main/SpeechNormalizer.swift) | 6 KB | Постобработка распознанного текста (фактически — нормализация чисел, аббревиатур, etc.). С тестами. |
| [`SpeechDetectionService.swift`](https://github.com/froggychips/interview-assistant/blob/main/SpeechDetectionService.swift) | 14 KB | Service layer для VAD-based event detection. |
| [`MemoryAwareRouter.swift`](https://github.com/froggychips/interview-assistant/blob/main/MemoryAwareRouter.swift) + [`MemoryManagement.swift`](https://github.com/froggychips/interview-assistant/blob/main/MemoryManagement.swift) | 9 KB + 12 KB | **Особо ценно:** routing решений под memory pressure. Естественно интегрируется с Froggy `MemoryPressureMonitor` — фактически тот же mental model. |
| [`GPUResourceManager.swift`](https://github.com/froggychips/interview-assistant/blob/main/GPUResourceManager.swift) | 6 KB | **GPU lock arbitration Whisper vs LLM.** Критично, если в Froggy одновременно работают `FroggyMLXWorker` (Qwen) и WhisperMLX — конкуренция за unified memory / Metal queues. |
| [`KeychainSecretStore.swift`](https://github.com/froggychips/interview-assistant/blob/main/KeychainSecretStore.swift) | 2.5 KB | Хранение API-ключей (Atlassian token и т.п.) в Keychain. |
| [`InterviewAssistant.entitlements`](https://github.com/froggychips/interview-assistant/blob/main/InterviewAssistant.entitlements) | 435 B | См. секцию [Permissions story](#permissions-story). |
| [`StructuredLogging.swift`](https://github.com/froggychips/interview-assistant/blob/main/StructuredLogging.swift) | 14 KB | Structured os.Logger обёртки. У Froggy уже есть `os.Logger` поверх unified log — можно стянуть только если у interview-assistant полезные patterns; иначе пропустить. |
| [`EventBuffer.swift`](https://github.com/froggychips/interview-assistant/blob/main/EventBuffer.swift) | 8 KB | Ring buffer для событий — концептуально близок Froggy `ContextStore`. |

### Что переносится со значительной адаптацией

| Файл | Зачем адаптация |
|---|---|
| [`TranscriptionService.swift`](https://github.com/froggychips/interview-assistant/blob/main/TranscriptionService.swift) (32 KB) | Логика двух потоков и orchestration; в Froggy надо переписать под dual-stream (mic + Discord), а в interview-assistant у user'а structure для interview-pair (interviewer/candidate). |
| [`ConversationOrchestrator.swift`](https://github.com/froggychips/interview-assistant/blob/main/ConversationOrchestrator.swift) (21 KB) + tests | Turn tracking, GPU lock arbitration, echo confidence — концепции переносятся, но trigger logic в interview-assistant заточен под «detected interview question → invoke AI». У нас trigger другой (см. open issue 1 в этом документе). |
| [`AudioSetupManager.swift`](https://github.com/froggychips/interview-assistant/blob/main/AudioSetupManager.swift) (25 KB) | Onboarding wizard для audio routing. Логика выбора loopback / process tap полезна, UI шаги под наш UX надо переписать. |
| [`MLXProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/MLXProvider.swift) (16 KB) | У нас уже свой `FroggyMLXWorker`. Сравнить и взять только то, что у нас отсутствует (например, оптимизации [KLEE-A..F](../peer-research/klee-mlx-optimizations.md), если interview-assistant их применил). |

### Что НЕ переносим (специфика interview use case)

* `OverlayWindow.swift`, `MainWindowController.swift`, `OnboardingStepViews.swift`,
  `ContentView.swift` (110 KB), `SettingsView.swift` (148 KB) — UI заточен под
  interview overlay; у Froggy свой menubar.
* `ContentClassifier.swift` (OCR класс. кода/configs/logs) — interview-specific.
  У Froggy уже есть `LushaBridge` для OCR, своё.
* `CodeGhostWriter.swift`, `Humanizer.swift`, `SystemPromptBuilder.swift`,
  `Prompt.swift` — interview ghost-writer / hint generator.
* `SimulatorView.swift`, `SimulatorManager.swift`, `BenchmarkManager 2.swift` —
  interview simulator / dev tool. У нас свой `bench/`.
* `OnboardingManager.swift`, `OnboardingWizardManager.swift` — interview-flow
  onboarding.
* `HotkeyManager.swift` — концептуально нам тоже понадобится hotkey, но
  лучше написать свой чище, чем чистить interview-specific bindings.

### Echo detection — обязательная зависимость

`AudioService.echoDetector` + методы `isEchoLikely()`, `getEchoConfidence()`,
`updateEchoDetector(with rms:)` решают **критическую** проблему:

> Если user слушает Discord через **спикеры** (а не headphones), его
> микрофон захватывает Discord output. Без echo detection транскрипт
> mic-потока будет дублировать Discord-поток с задержкой.

В interview-assistant — 300 ms acoustic correlation между mic RMS и
system RMS. Если корреляция выше threshold → mic-buffer считается
эхом и не уходит в транскрипцию.

В нашем design doc это было **не упомянуто** — добавить в Phase 1
обязательным компонентом, не опциональным.

### Вопросы которые остаются после reuse-аудита

1. **Почему interview-assistant «нерабочий»?** User написал что прототип
   не работает. Нужно понять конкретно: build fail на актуальной Xcode?
   Какой-то TCC-prompt не вылазит на macOS 15? WhisperMLX крашит на load?
   GPU contention под одновременной нагрузкой? Без этого знания мы
   рискуем унаследовать тот же блокер.
2. **Какая версия mlx-swift в interview-assistant vs в Froggy?**
   `Package.resolved` обоих сравнить — если interview-assistant на
   старой mlx-swift, перенос потребует адаптации API.
3. **Есть ли в interview-assistant working tests?** Список тестовых
   файлов (`InterviewAssistantTests/`) внушительный — 12 файлов, ~1000
   строк. Если они зелёные на main — это сильный сигнал что код
   не «полностью нерабочий», просто end-to-end интеграция не дошла.

---

## Источники

* **[`froggychips/interview-assistant`](https://github.com/froggychips/interview-assistant)** —
  собственный prior art user'а. Главный источник готовых компонентов
  (см. [Reuse from interview-assistant](#reuse-from-interview-assistant)).
* [Apple — ScreenCaptureKit framework](https://developer.apple.com/documentation/screencapturekit)
* [Apple — `CATapDescription` (macOS 14.4+)](https://developer.apple.com/documentation/coreaudio/catapdescription)
* [WWDC24 — Capturing system audio with Core Audio taps](https://developer.apple.com/videos/play/wwdc2024/10145/)
* [Atlassian Remote MCP server](https://www.atlassian.com/platform/remote-mcp-server)
* [pyannote-audio — speaker diarization](https://github.com/pyannote/pyannote-audio)
  (для возможного Phase 4)
* [WhisperKit — argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) —
  rejected alternative (см. секцию [Транскрипция](#транскрипция--whispermlx-не-whisperkit)).
