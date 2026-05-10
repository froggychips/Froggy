# Froggy Ecosystem Map

🌐 **English** · [Русский](ECOSYSTEM.ru.md)

Visual overview of all repositories, processes, IPC channels, and data flows in the Froggy ecosystem.

---

## Repositories

| Repo | Role |
|---|---|
| [Froggy](https://github.com/froggychips/Froggy) | Core daemon — local LLM inference, screen OCR, memory management |
| [FroggyKit](https://github.com/froggychips/FroggyKit) | Shared Swift package — `FroggyClient` IPC client |
| [froggy-mcp](https://github.com/froggychips/froggy-mcp) | MCP server — bridges Claude Code to the Froggy daemon |
| [froggy-sre](https://github.com/froggychips/froggy-sre) | SRE agent — incident analysis pipeline with k8s context |

---

## Full Ecosystem Map

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  CLOUD / USER                                                                    ║
║                                                                                  ║
║  ┌──────────────┐   ┌──────────────────────┐   ┌────────────────────────────┐   ║
║  │  Claude Code │   │  FroggyMenuBar        │   │  FroggyCLI  (froggy)       │   ║
║  │  (cloud)     │   │  SwiftUI MenuBarExtra │   │  status·gen·ctx·load·snap  │   ║
║  └──────┬───────┘   └──────────┬────────────┘   └──────────┬─────────────────┘   ║
╚═════════╪════════════════════════╪══════════════════════════╪════════════════════╝
          │ stdio  JSON-RPC 2.0    │  Unix socket             │  Unix socket
          │  (MCP)                 │  JSON-line (IPCClient)   │  JSON-line (IPCClient)
    ┌─────┴──────────────────┐     │                          │
    ▼                        ▼     │                          │
╔══════════════════════════════════════════════════════════════════════════════════╗
║  MCP LAYER                                                                       ║
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
                      │  FroggyClient (IPC client)        │
                      │  shared by froggy-mcp + sre       │
                      └────────────────┬──────────────────┘
                                       │ Unix socket
                                       │ ~/Library/…/froggy.sock
                                       │
╔══════════════════════════════════════▼═══════════════════════════════════════════╗
║  DAEMON  [FroggyDaemon]   dep: VortexCore + LushaBridge + LushaExperimental      ║
║                                                                                  ║
║  ┌──────────────────────────────────────────────────────────────────────────┐   ║
║  │  VortexCore                                                               │   ║
║  │                                                                           │   ║
║  │  VortexCoordinator                                                        │   ║
║  │       │                                                                   │   ║
║  │  ┌────┴──────────┐  ┌─────────────────┐  ┌────────────────┐  ┌────────┐  │   ║
║  │  │  VortexActor  │  │  MLXSupervisor  │  │ AudioSupervisor│  │  IPC   │  │   ║
║  │  │  SIGSTOP/CONT │  │  subprocess mgr │  │ subprocess mgr │  │ Server │  │   ║
║  │  │  ProcessFinder│  └───────┬─────────┘  └───────┬────────┘  │AF_UNIX │  │   ║
║  │  │  ProcessClass.│          │ stdin/stdout        │ stdin/out │ socket │  │   ║
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
║  │  │(SQLite teleme.)│                        │  FrozenPidsStore            │ │   ║
║  │  │FreezeRanker    │                        │  WorkspaceEventSource       │ │   ║
║  │  └────────────────┘                        └─────────────────────────────┘ │   ║
║  └──────────────────────────────────────────────────────────────────────────┘   ║
║                                                                                  ║
║  ┌──────────────────────────────────────────────────────────────────────────┐   ║
║  │  LushaBridge  (context pipeline)                                          │   ║
║  │                                                                           │   ║
║  │  SCStream (ScreenCaptureKit, persistent)                                  │   ║
║  │    └─► ScreenStream                                                       │   ║
║  │            └─► FramePacer ─► FrameDigest (32×32) ─► SimilarityScorer    │   ║
║  │                    └── changed? ──► VisionActor (Vision.framework OCR)   │   ║
║  │                                        └─► Redactor (secrets strip)      │   ║
║  │                                               └─► ContextStore (30 snaps)│   ║
║  │                                                                           │   ║
║  │  LushaAccessor plugin API                                                 │   ║
║  │  LushaBridge:       OCRAccessor · FrontmostAppAccessor                    │   ║
║  │  LushaExperimental: experimental sensors (AccessorRegistrar)              │   ║
║  └──────────────────────────────────────────────────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════════╝
          │ spawn                               │ spawn
          ▼                                     ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  WORKERS  (child processes — ADR-0008)                                           ║
║                                                                                  ║
║  ┌────────────────────────────────────────┐  ┌─────────────────────────────┐   ║
║  │  FroggyMLXWorker                        │  │  FroggyAudioWorker          │   ║
║  │                                         │  │                             │   ║
║  │  mlx-swift-lm + HuggingFace Tokenizers  │  │  CATapDescription (Discord) │   ║
║  │  Metal shaders (default.metallib)       │  │  AVAudioEngine (mic)        │   ║
║  │  KV-cache quantization (8-bit default)  │  │  SFSpeechRecognizer         │   ║
║  │  Streaming token generation             │  │  → transcript → daemon      │   ║
║  │  [kill on unloadModel → RAM freed]      │  │                             │   ║
║  └────────────────────────────────────────┘  │  FroggyMLXWorkerFake        │   ║
║                                               │  (test double, no MLX)      │   ║
║                                               └─────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Package Dependencies

```
Froggy (main)
  ├── FroggyDaemon     → VortexCore + LushaBridge + LushaExperimental
  ├── FroggyMenuBar    → VortexCore
  ├── FroggyCLI        → VortexCore
  ├── FroggyMLXWorker  → MLXWorkerProtocol + mlx-swift-lm + swift-transformers
  ├── FroggyAudioWorker→ AudioWorkerProtocol
  └── VortexCore       → MLXWorkerProtocol + AudioWorkerProtocol + sqlite3

FroggyKit  (shared, v0.3+)
  └── FroggyClient (IPC)

froggy-mcp
  └── FroggyMCPServer  → FroggyKit

froggy-sre
  ├── FroggySRECore    → FroggyKit
  └── FroggySRE        → FroggySRECore
```

---

## IPC Protocols

| Channel | Format | Transport |
|---|---|---|
| Claude Code ↔ froggy-mcp | JSON-RPC 2.0 (MCP) | stdio |
| Claude Code ↔ froggy-sre | JSON-RPC 2.0 (MCP) | stdio |
| froggy-mcp / sre ↔ daemon | JSON-line | AF_UNIX socket |
| daemon ↔ FroggyMLXWorker | JSON-line | stdin / stdout |
| daemon ↔ FroggyAudioWorker | JSON-line | stdin / stdout |
| macOS → daemon | `dispatch_source_memorypressure` | kernel |
| daemon → frozen apps | `SIGSTOP` / `SIGCONT` | `ProcessClassifier` |

---

## Context Pipeline

```
SCStream (ScreenCaptureKit)
  └─► ScreenStream
        └─► FramePacer ─► FrameDigest (32×32 hash)
                  └── unchanged? → skip OCR
                  └── changed?   → VisionActor (Vision OCR)
                                       └─► Redactor (AWS/PAT/JWT/Luhn/…)
                                               └─► ContextStore (sliding 30 snapshots)
                                                         └─► PromptAugmenter
                                                               (on generate useContext:true)
                                                                     └─► MLXSupervisor
                                                                               └─► FroggyMLXWorker
```

---

*Part of the [Froggy](https://github.com/froggychips/Froggy) ecosystem.*
