# Карта экосистемы Froggy

🌐 [English](ECOSYSTEM.md) · **Русский**

Визуальная схема всех репозиториев, процессов, IPC-каналов и потоков данных экосистемы Froggy.

---

## Репозитории

| Репо | Роль |
|---|---|
| [Froggy](https://github.com/froggychips/Froggy) | Основной демон — локальный LLM-инференс, OCR экрана, управление памятью |
| [FroggyKit](https://github.com/froggychips/FroggyKit) | Общий Swift-пакет — IPC-клиент `FroggyClient` |
| [froggy-mcp](https://github.com/froggychips/froggy-mcp) | MCP-сервер — мост между Claude Code и демоном Froggy |
| [froggy-sre](https://github.com/froggychips/froggy-sre) | SRE-агент — пайплайн анализа инцидентов с k8s-контекстом |

---

## Полная карта экосистемы

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  ОБЛАКО / ПОЛЬЗОВАТЕЛЬ                                                           ║
║                                                                                  ║
║  ┌──────────────┐   ┌──────────────────────┐   ┌────────────────────────────┐   ║
║  │  Claude Code │   │  FroggyMenuBar        │   │  FroggyCLI  (froggy)       │   ║
║  │  (облако)    │   │  SwiftUI MenuBarExtra │   │  status·gen·ctx·load·snap  │   ║
║  └──────┬───────┘   └──────────┬────────────┘   └──────────┬─────────────────┘   ║
╚═════════╪════════════════════════╪══════════════════════════╪════════════════════╝
          │ stdio  JSON-RPC 2.0    │  Unix socket             │  Unix socket
          │  (MCP)                 │  JSON-line (IPCClient)   │  JSON-line (IPCClient)
    ┌─────┴──────────────────┐     │                          │
    ▼                        ▼     │                          │
╔══════════════════════════════════════════════════════════════════════════════════╗
║  MCP-СЛОЙ                                                                        ║
║                                                                                  ║
║  ┌──────────────────────────────────┐  ┌──────────────────────────────────────┐ ║
║  │  froggy-mcp  [FroggyMCPServer]   │  │  froggy-sre  [FroggySRE+SRECore]     │ ║
║  │                                  │  │                                      │ ║
║  │  froggy_status  froggy_context   │  │  sre_analyze                         │ ║
║  │  froggy_generate  froggy_listen  │  │    → K8sContextFetcher (kubectl)      │ ║
║  │  froggy_transcript  froggy_speak │  │      → Analyzer → Hypothesis         │ ║
║  │  froggy_freeze  froggy_pressure  │  │      → Critic   → Fix → Risk         │ ║
║  │  froggy_thaw_all  froggy_recap   │  │  sre_history  (~/.froggy-sre/)       │ ║
║  │  froggy_chat  froggy_inject      │  │  LLMRouter ──► Froggy ──► Anthropic  │ ║
║  │                                  │  │  daemon mode: /tmp/froggy-sre.sock   │ ║
║  │  dep: FroggyKit                  │  │  dep: FroggyKit                      │ ║
║  └───────────────┬──────────────────┘  └──────────────────┬───────────────────┘ ║
╚══════════════════╪═══════════════════════════════════════════╪═══════════════════╝
                   │                                           │
                   │  ┌──────────────────────────────────┐    │
                   └─►│         FroggyKit                 │◄───┘
                      │  FroggyClient (IPC-клиент)        │
                      │  используется froggy-mcp + sre    │
                      └────────────────┬──────────────────┘
                                       │ Unix socket
                                       │ ~/Library/…/froggy.sock
                                       │
╔══════════════════════════════════════▼═══════════════════════════════════════════╗
║  ДЕМОН  [FroggyDaemon]   dep: VortexCore + LushaBridge + LushaExperimental       ║
║                                                                                  ║
║  ┌──────────────────────────────────────────────────────────────────────────┐   ║
║  │  VortexCore                                                               │   ║
║  │                                                                           │   ║
║  │  VortexCoordinator                                                        │   ║
║  │       │                                                                   │   ║
║  │  ┌────┴──────────┐  ┌─────────────────┐  ┌────────────────┐  ┌────────┐  │   ║
║  │  │  VortexActor  │  │  MLXSupervisor  │  │ AudioSupervisor│  │  IPC   │  │   ║
║  │  │  SIGSTOP/CONT │  │  менеджер проц. │  │ менеджер проц. │  │ Server │  │   ║
║  │  │  ProcessFinder│  └───────┬─────────┘  └───────┬────────┘  │AF_UNIX │  │   ║
║  │  │  ProcessClass.│          │ stdin/stdout        │ stdin/out │ сокет  │  │   ║
║  │  └────┬──────────┘          │ JSON-line           │ JSON-line └────────┘  │   ║
║  │       │             [MLXWorkerProtocol]   [AudioWorkerProtocol]            │   ║
║  │  ┌────┴──────────┐                                                        │   ║
║  │  │  PageoutChain │  ┌──────────────────┐  ┌─────────────────────────────┐ │   ║
║  │  │  machVM       │  │MemoryPressure    │  │  PromptAugmenter            │ │   ║
║  │  │  jetsam       │  │Monitor           │  │  ContextStore reader        │ │   ║
║  │  │  scratch      │  │dispatch_source   │  └─────────────────────────────┘ │   ║
║  │  └───────────────┘  │.memorypressure   │                                  │   ║
║  │  ┌────────────────┐ └──────────────────┘  ┌─────────────────────────────┐ │   ║
║  │  │FreezeStatsStore│                        │  SessionStore               │ │   ║
║  │  │(SQLite телем.) │                        │  FrozenPidsStore            │ │   ║
║  │  │FreezeRanker    │                        │  WorkspaceEventSource       │ │   ║
║  │  └────────────────┘                        └─────────────────────────────┘ │   ║
║  └──────────────────────────────────────────────────────────────────────────┘   ║
║                                                                                  ║
║  ┌──────────────────────────────────────────────────────────────────────────┐   ║
║  │  LushaBridge  (контекстный пайплайн)                                      │   ║
║  │                                                                           │   ║
║  │  SCStream (ScreenCaptureKit, persistent)                                  │   ║
║  │    └─► ScreenStream                                                       │   ║
║  │            └─► FramePacer ─► FrameDigest (32×32) ─► SimilarityScorer    │   ║
║  │                    └── без изменений? → OCR пропускается                 │   ║
║  │                    └── изменился?     → VisionActor (Vision OCR)         │   ║
║  │                                           └─► Redactor (зачистка секретов│   ║
║  │                                                  └─► ContextStore (30 сн.)│   ║
║  │                                                                           │   ║
║  │  Плагин-API LushaAccessor                                                 │   ║
║  │  LushaBridge:       OCRAccessor · FrontmostAppAccessor                    │   ║
║  │  LushaExperimental: экспериментальные сенсоры (AccessorRegistrar)         │   ║
║  └──────────────────────────────────────────────────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════════╝
          │ spawn                               │ spawn
          ▼                                     ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  ВОРКЕРЫ  (дочерние процессы — ADR-0008)                                         ║
║                                                                                  ║
║  ┌────────────────────────────────────────┐  ┌─────────────────────────────┐   ║
║  │  FroggyMLXWorker                        │  │  FroggyAudioWorker          │   ║
║  │                                         │  │                             │   ║
║  │  mlx-swift-lm + HuggingFace Tokenizers  │  │  CATapDescription (Discord) │   ║
║  │  Metal-шейдеры (default.metallib)       │  │  AVAudioEngine (микрофон)   │   ║
║  │  KV-кеш квантизация (8-бит по умолч.)   │  │  SFSpeechRecognizer         │   ║
║  │  Стримящаяся генерация токенов          │  │  → транскрипт → демон       │   ║
║  │  [kill при unloadModel → RAM возвращается│  │                             │   ║
║  └────────────────────────────────────────┘  │  FroggyMLXWorkerFake        │   ║
║                                               │  (тест-двойник, без MLX)    │   ║
║                                               └─────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Граф зависимостей пакетов

```
Froggy (основной)
  ├── FroggyDaemon     → VortexCore + LushaBridge + LushaExperimental
  ├── FroggyMenuBar    → VortexCore
  ├── FroggyCLI        → VortexCore
  ├── FroggyMLXWorker  → MLXWorkerProtocol + mlx-swift-lm + swift-transformers
  ├── FroggyAudioWorker→ AudioWorkerProtocol
  └── VortexCore       → MLXWorkerProtocol + AudioWorkerProtocol + sqlite3

FroggyKit  (общий, v0.3+)
  └── FroggyClient (IPC)

froggy-mcp
  └── FroggyMCPServer  → FroggyKit

froggy-sre
  ├── FroggySRECore    → FroggyKit
  └── FroggySRE        → FroggySRECore
```

---

## IPC-протоколы

| Канал | Формат | Транспорт |
|---|---|---|
| Claude Code ↔ froggy-mcp | JSON-RPC 2.0 (MCP) | stdio |
| Claude Code ↔ froggy-sre | JSON-RPC 2.0 (MCP) | stdio |
| froggy-mcp / sre ↔ демон | JSON-line | AF_UNIX socket |
| демон ↔ FroggyMLXWorker | JSON-line | stdin / stdout |
| демон ↔ FroggyAudioWorker | JSON-line | stdin / stdout |
| macOS → демон | `dispatch_source_memorypressure` | ядро |
| демон → замороженные приложения | `SIGSTOP` / `SIGCONT` | `ProcessClassifier` |

---

## Контекстный пайплайн

```
SCStream (ScreenCaptureKit)
  └─► ScreenStream
        └─► FramePacer ─► FrameDigest (32×32 хеш)
                  └── без изменений? → OCR пропускается
                  └── изменился?     → VisionActor (Vision OCR)
                                           └─► Redactor (AWS/PAT/JWT/Luhn/…)
                                                   └─► ContextStore (скользящее окно 30 снапшотов)
                                                             └─► PromptAugmenter
                                                                   (при generate useContext:true)
                                                                         └─► MLXSupervisor
                                                                                   └─► FroggyMLXWorker
```

---

*Часть экосистемы [Froggy](https://github.com/froggychips/Froggy).*
