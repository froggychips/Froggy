# Froggy 🐸

🌐 [English](README.md) · **Русский**

**AI-powered macOS Resource & Context Orchestrator** — нативный Swift 6
демон для Apple Silicon, который снимает экран, делает OCR, отдаёт контекст
локальной MLX-модели и при загрузке тяжёлой модели подмораживает фоновые
приложения, чтобы освободить unified memory.

К демону прилагается menubar-приложение (SwiftUI `MenuBarExtra`) и Unix-socket
IPC, через который можно дёргать его из любого языка.

**Статус:** working personal-use scaffolding, не продукт. См.
[`docs/POSITIONING.md`](docs/POSITIONING.md).

📖 [THESIS](docs/THESIS.md) · [POSITIONING](docs/POSITIONING.md) · [FAQ](docs/FAQ.md) · [ADR'ы](docs/adr/) · [Packaging](packaging/README.md)
📬 Контакт: [@froggychips](https://t.me/froggychips) в Telegram
📜 Лицензия: [MIT](LICENSE)

## Возможности

- **Dynamic RAM Recovery (реактивный)** — `MemoryPressureMonitor`
  слушает `dispatch_source_memorypressure` и публикует `.normal/.warning/.critical`
  с debounce'ом понижения (`pressureCooldownSeconds`). Координатор морозит
  по двум tier'ам: tier-1 при warning (Spotify, Discord, Telegram), tier-2
  дополнительно при critical (Slack, Notion, Teams). Старое поле
  `freezeBundleIds` deprecated, маппится в tier-1 для совместимости.
  Подробнее — `docs/adr/0006-reactive-memory-pressure.md`.
- **Принудительный pageout** после SIGSTOP — `SIGSTOP` сам по себе RAM не
  возвращает. `PageoutChain` пробует одну из трёх стратегий: `machVM`
  (`task_for_pid` + `mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT)`, требует
  Developer ID + entitlement), `jetsam` (`memorystatus_control` idle-band,
  default — без entitlement'ов), `scratch` (alloc/memset/free). Fallback
  по цепочке. Подробнее — `docs/adr/0007-pageout-strategies.md`.
- **Default-deny классификация процессов** — заморозить можно только то, что
  лежит под `/Applications/`, `~/Applications/` или `/opt/homebrew/Cellar/`.
  Системные бинарники неприкосновенны.
- **Persistent SCStream** — захват кадров через `SCStream` с делегатом, без
  пересоздания `SCShareableContent` на каждый цикл.
- **Frame-diff** — 32×32 grayscale-отпечаток кадра; если экран не изменился,
  OCR не запускается.
- **Secret redaction** — `Redactor` режет AWS-ключи, GitHub PAT, Anthropic /
  OpenAI / Slack-токены, JWT, bearer-заголовки, `password=`/`api_key=`/...
  и валидированные по Luhn кредитки **до** записи на диск.
- **Sliding context window** — последние 30 redacted-снапшотов, по запросу
  отдаются как текстовый блок.
- **MLX-инференс в child process** — `FroggyMLXWorker` живёт в отдельном
  процессе, общается с демоном через JSON-line на stdin/stdout. На
  `unloadModel` worker убивается — это единственный надёжный способ
  вернуть peak unified memory ядру. Демон без модели весит ~50 MB, не
  ~500 MB. Подробнее — `docs/adr/0008-mlx-subprocess-isolation.md`.
- **KV-cache квантизация** — `kvCacheBits` (16/8/4, default 8) режет
  память KV-кэша примерно вдвое на длинных промптах. Передаётся в
  worker через `--kv-bits`; текущее значение видно в IPC `status`.
  Подробнее — `docs/adr/0009-kv-cache-quantization.md`.
- **Streaming MLX-инференс** — токены идут в IPC-клиент по мере генерации.
- **`os_signpost`** — точки на горячих путях для Instruments.
- **Boot-time recovery** — при старте читает `frozen.pids` и `SIGCONT`-ит всё,
  что осталось от прошлого запуска (если демон убили мимо handler'а).
- **Plugin API (`LushaAccessor`)** — встроенные `OCRAccessor`,
  `FrontmostAppAccessor`; новые добавляются за ~30 строк кода.

## Стек

- Swift 6 (strict concurrency + ExistentialAny). macOS 14+ (Sonoma).
- ScreenCaptureKit, Vision, MLX (`ml-explore/mlx-swift-lm`),
  HuggingFace Tokenizers.
- Без Python — всё на нативном Swift API.

## Структура

```
Sources/
  FroggyDaemon/           — executable, демон с IPC-сервером
  FroggyMenuBar/          — SwiftUI MenuBarExtra клиент
  FroggyMLXWorker/        — child-process worker для MLX-инференса
  VortexCore/             — actors: Vortex (freeze), MLXSupervisor,
                            Coordinator, ProcessClassifier,
                            FrozenPidsStore, IPC, FroggyConfig,
                            MemoryPressureMonitor, PageoutChain
  LushaBridge/            — VisionActor, ScreenStream, FrameDigest,
                            Redactor, ContextStore, LushaAccessor,
                            OCR/Frontmost
Tests/                    — 100+ тестов, swift test --parallel
docs/adr/                 — architectural decision records
packaging/                — LaunchAgent .plist + entitlements + install recipe
.github/workflows/        — ci-selfhosted.yml (primary, self-hosted ARM64)
                            + ci.yml (hosted macos-14 fallback)
```

## Быстрый старт

```sh
# Собрать всё (демон + menubar + CLI + worker).
# `make build` оборачивает `swift build -c release` плюс pre-build шаг
# компиляции `default.metallib` из mlx-swift checkout. SwiftPM по умолчанию
# не компилирует Metal-шейдеры, и без этого worker падает на первой
# MLX-операции — см. ADR-0013.
make build

# Запустить демон с моделью (HuggingFace MLX-репо, скачанный локально)
.build/release/FroggyDaemon --model-path ~/models/qwen3-4b-4bit

# В другом терминале — через CLI-обёртку froggy:
swift run froggy status
swift run froggy gen --context "what app am I in right now?"
swift run froggy ctx --max 2000
swift run froggy load ~/models/qwen3-4b-4bit
swift run froggy snap frontmost

# Или сырьём через JSON-протокол:
echo '{"cmd":"status"}' \
    | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
echo '{"cmd":"generate","prompt":"hi","useContext":true,"maxTokens":50}' \
    | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
```

Или через menubar-приложение: `swift run FroggyMenuBar` — иконка-лягушка
в строке меню, статус, поле для пути модели, Load/Unload, recent context,
Thaw all.

## Использовать Froggy только как менеджер памяти (без LLM)

Если ты уже используешь Ollama, LM Studio или другой локальный LLM-инструмент
и хочешь только подсистему управления памятью — запусти демон без модели:

```sh
# Без --model-path — демон весит ~50 МБ, вся логика freeze/thaw работает.
.build/release/FroggyDaemon
```

`MemoryPressureMonitor` по-прежнему смотрит на `dispatch_source_memorypressure`
и замораживает/размораживает настроенные приложения. Настрой, какие процессы
замораживать в `config.json`, чтобы *inference*-процесс (Ollama, llama.cpp и т. д.)
получал больше unified memory при росте давления:

```json
{
  "freezeTier1BundleIds": ["com.spotify.client", "com.hnc.Discord"],
  "freezeTier2BundleIds": ["com.tinyspeck.slackmacgap", "notion.id"]
}
```

Захват экрана и контекстное окно работают как обычно. Команды `generate` /
`loadModel` вернут ошибку пока модель не загружена через `froggy load <path>`.

## Context-aware generation

Передай `useContext: true` (через `froggy gen --context …` или прямо в IPC) —
демон достанет последний sliding-window OCR из `ContextStore`, прогонит через
шаблон в `PromptAugmenter` (`docs/adr/0005-…`) и подсунет модели как system
context перед твоим вопросом. Модель получает что-то вроде:

```
You are an assistant with awareness of the user's current screen context.
…
--- CONTEXT ---
[2026-05-06T19:24:11Z] Slack #general @yar: deploy looks broken
[2026-05-06T19:24:13Z] CI run failed — job 'integration-tests' status=failure
--- END CONTEXT ---

User: should I roll back the deploy?
Assistant:
```

Без флага модель получает только `prompt` (по дефолту useContext=false).

## Конфиг

Лежит в `~/Library/Application Support/Froggy/config.json` (mode `0600`).
Все поля опциональны, имеют дефолты:

```json
{
  "modelPath": "/Users/me/models/qwen3-4b-4bit",
  "gpuMemoryLimitBytes": 8589934592,
  "captureIntervalSeconds": 2,
  "freezeTier1BundleIds": ["com.spotify.client", "com.hnc.Discord"],
  "freezeTier2BundleIds": ["com.tinyspeck.slackmacgap", "notion.id"],
  "pressureCooldownSeconds": 60,
  "pageoutStrategy": "jetsam",
  "pageoutScratchMB": 256,
  "mlxWorkerPath": "/usr/local/libexec/FroggyMLXWorker",
  "kvCacheBits": 8,
  "ipcSocketPath": "/Users/me/Library/Application Support/Froggy/froggy.sock",
  "frameSimilarityThreshold": 0.98,
  "contextWindowSize": 30,
  "contextMaxChars": 4096
}
```

CLI-флаги (`--model-path`, `--capture-interval`) и env-переменные
(`FROGGY_MODEL_PATH`, `FROGGY_CAPTURE_INTERVAL`) переопределяют значения
из файла.

## IPC-команды

| `cmd` | Параметры | Что делает |
|---|---|---|
| `status` | — | `capturing` / `modelLoaded` / `modelPath` / `memoryPressure` / `frozen` / `snapshots` / `lastCaptureError` |
| `generate` | `prompt`, `maxTokens?`, `useContext?` | генерация (стримящаяся). `useContext: true` → подмешивает recent context в prompt через `PromptAugmenter` |
| `context` | `maxChars?` | склеенные последние OCR-снапшоты до лимита |
| `loadModel` | `path` | hot-swap MLX-модели |
| `unloadModel` | — | выгрузить + `MLX.Memory.clearCache()` |
| `accessors` | — | список зарегистрированных `LushaAccessor` |
| `snapshot` | `accessor` | текущий snapshot одного accessor'а |
| `freeze` | `pid` | `SIGSTOP` (через `ProcessClassifier`) |
| `thawAll` | — | `SIGCONT` всем замороженным |
| `pressure` | — | `pressureLevel` / `tier1Frozen[]` / `tier2Frozen[]` / `secondsInLevel` |

## Установка как LaunchAgent

См. [`packaging/README.md`](packaging/README.md) — codesign + notarytool +
`launchctl bootstrap`. Вне CI: требует Apple Developer ID.

## Troubleshooting

`make logbundle` собирает unified-log архив с предикатом
`subsystem == "com.froggychips.froggy"` в `./froggy.logarchive` —
для прикрепления к bug-report'у. Чтобы ограничить временной диапазон,
запускай `scripts/logbundle.sh --last 1h` (или другую длительность)
напрямую.

`make session-summary` собирает расширенный post-session bundle:
unified-log архив (по умолчанию за последний час), SQLite-дамп
freeze-events из `freeze_stats.sqlite`, текущие snapshot'ы
`frozen.pids` и `config.json`, системное состояние памяти (`vm_stat`
/ `memory_pressure`), live IPC-снимки (`status` / `pressure` /
`accessors`) если демон запущен, плюс шаблон `notes.md`. Каждый шаг
best-effort — отсутствующие куски перечислены в `MANIFEST.txt`.
Результат — tarball рядом с рабочей директорией. Для другого
интервала или формата: `scripts/session-summary.sh --last 4h --no-tar`
напрямую.

## Документация

ADR-папка [`docs/adr/`](docs/adr/) описывает ключевые решения:
actors-over-locks, AF_UNIX-over-XPC, Codable-config, Coordinator,
реактивный memory pressure, pageout-стратегии, MLX subprocess isolation.

---
*Created for Apple Silicon. Built for Intelligence.*
