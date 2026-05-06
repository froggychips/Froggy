# Froggy 🐸

**AI-powered macOS Resource & Context Orchestrator** — нативный Swift 6
демон для Apple Silicon, который снимает экран, делает OCR, отдаёт контекст
локальной MLX-модели и при загрузке тяжёлой модели подмораживает фоновые
приложения, чтобы освободить unified memory.

К демону прилагается menubar-приложение (SwiftUI `MenuBarExtra`) и Unix-socket
IPC, через который можно дёргать его из любого языка.

## Возможности

- **Dynamic RAM Recovery** — перед `loadModel` шлёт `SIGSTOP` приложениям из
  `freezeBundleIds` (Slack, Discord, Spotify, Teams, Dropbox по умолчанию),
  при `unloadModel` или при выходе — `SIGCONT`.
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
  VortexCore/             — actors: Vortex (kill), MLX, Coordinator,
                            ProcessClassifier, FrozenPidsStore, IPC,
                            FroggyConfig
  LushaBridge/            — VisionActor, ScreenStream, FrameDigest, Redactor,
                            ContextStore, LushaAccessor, OCR/Frontmost
Tests/                    — 63 теста, swift test --parallel
docs/adr/                 — 4 ADR'a
packaging/                — LaunchAgent .plist + entitlements + install recipe
.github/workflows/ci.yml  — macos-14, build + test, кэш .build на Package.swift
```

## Быстрый старт

```sh
# Собрать всё (демон + menubar)
swift build -c release

# Запустить демон с моделью (HuggingFace MLX-репо, скачанный локально)
swift run FroggyDaemon --model-path ~/models/qwen3-4b-4bit

# В другом терминале — потрогать IPC напрямую
echo '{"cmd":"status"}' \
    | nc -U ~/Library/Application\ Support/Froggy/froggy.sock

echo '{"cmd":"context","maxChars":1000}' \
    | nc -U ~/Library/Application\ Support/Froggy/froggy.sock

# Streaming-генерация (несколько JSON-строк, последняя c "final":true)
echo '{"cmd":"generate","prompt":"hi","maxTokens":50}' \
    | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
```

Или через menubar-приложение: `swift run FroggyMenuBar` — иконка-лягушка
в строке меню, статус, поле для пути модели, Load/Unload, recent context,
Thaw all.

## Конфиг

Лежит в `~/Library/Application Support/Froggy/config.json` (mode `0600`).
Все поля опциональны, имеют дефолты:

```json
{
  "modelPath": "/Users/me/models/qwen3-4b-4bit",
  "gpuMemoryLimitBytes": 8589934592,
  "captureIntervalSeconds": 2,
  "freezeBundleIds": ["com.tinyspeck.slackmacgap", "com.spotify.client"],
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
| `generate` | `prompt`, `maxTokens?` | генерация. Если handler стримит — токены идут отдельными JSON-строками |
| `context` | `maxChars?` | склеенные последние OCR-снапшоты до лимита |
| `loadModel` | `path` | hot-swap MLX-модели |
| `unloadModel` | — | выгрузить + `MLX.Memory.clearCache()` |
| `accessors` | — | список зарегистрированных `LushaAccessor` |
| `snapshot` | `accessor` | текущий snapshot одного accessor'а |
| `freeze` | `pid` | `SIGSTOP` (через `ProcessClassifier`) |
| `thawAll` | — | `SIGCONT` всем замороженным |

## Установка как LaunchAgent

См. [`packaging/README.md`](packaging/README.md) — codesign + notarytool +
`launchctl bootstrap`. Вне CI: требует Apple Developer ID.

## Документация

ADR-папка [`docs/adr/`](docs/adr/) описывает ключевые решения:
actors-over-locks, AF_UNIX-over-XPC, Codable-config, Coordinator-pattern.

---
*Created for Apple Silicon. Built for Intelligence.*
