# Froggy 🐸

🌐 **English** · [Русский](README.ru.md)

> **Local LLM with screen-context awareness for Apple Silicon Macs — designed from the ground up for 8 GB unified memory.**

Most local-LLM tools assume you have 16+ GB RAM. Froggy doesn't. It runs a
small MLX model alongside aggressive unified-memory management — freezing
background apps under real memory pressure (`SIGSTOP` + forced pageout),
isolating MLX inference in a child process so unloading actually returns
RAM to the kernel — so a 3–4 B model can coexist with your daily workflow
on entry-level Apple Silicon.

It also captures your screen via `ScreenCaptureKit`, runs Vision OCR with
secret redaction **before** anything hits disk, and feeds that as context
to the model — so you can ask about what you're looking at without
sending anything to the cloud.

A SwiftUI `MenuBarExtra` app and a Unix-socket JSON IPC ship with the
daemon, so you can drive it from any language.

**Status:** working personal-use scaffolding. Not a product. See
[`docs/POSITIONING.md`](docs/POSITIONING.md) for what this is and isn't.

📖 [THESIS](docs/THESIS.md) · [POSITIONING](docs/POSITIONING.md) · [FAQ](docs/FAQ.md) · [ADRs](docs/adr/) · [Packaging](packaging/README.md)
📬 Contact: [@froggychips](https://t.me/froggychips) on Telegram
📜 License: [MIT](LICENSE)

## Features

- **Reactive Dynamic RAM Recovery** — `MemoryPressureMonitor` listens
  on `dispatch_source_memorypressure` and emits `.normal/.warning/.critical`
  with downgrade debouncing (`pressureCooldownSeconds`). The coordinator
  freezes apps in two tiers: tier-1 on warning (Spotify, Discord, Telegram),
  tier-2 additionally on critical (Slack, Notion, Teams). The legacy
  `freezeBundleIds` field is deprecated and aliased to tier-1 for
  backwards compatibility. See `docs/adr/0006-reactive-memory-pressure.md`.
- **Forced pageout** after `SIGSTOP` — `SIGSTOP` alone does not return
  RAM. `PageoutChain` tries one of three strategies: `machVM`
  (`task_for_pid` + `mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT)`, requires
  Developer ID + entitlement), `jetsam` (`memorystatus_control` idle band,
  the default — no entitlements needed), `scratch` (alloc/memset/free).
  Falls back through the chain. See `docs/adr/0007-pageout-strategies.md`.
- **Default-deny process classification** — only apps under
  `/Applications/`, `~/Applications/` or `/opt/homebrew/Cellar/` can be
  frozen. System binaries are never touched.
- **Persistent SCStream** — frame capture via `SCStream` with a delegate,
  no `SCShareableContent` rebuild per cycle.
- **Frame diff** — 32×32 grayscale fingerprint per frame; OCR is skipped
  if the screen hasn't changed.
- **Secret redaction** — `Redactor` strips AWS keys, GitHub PATs,
  Anthropic / OpenAI / Slack tokens, JWTs, bearer headers,
  `password=`/`api_key=`/... values, and Luhn-validated credit cards
  **before** anything is written to disk.
- **Sliding context window** — the last 30 redacted snapshots, returned
  on demand as a single text block.
- **MLX inference in a child process** — `FroggyMLXWorker` runs in its
  own process, talks to the daemon over JSON-line on stdin/stdout. On
  `unloadModel` the worker is killed — the only reliable way to actually
  return peak unified memory to the kernel. The daemon weighs ~50 MB
  without a model loaded, not ~500 MB. See
  `docs/adr/0008-mlx-subprocess-isolation.md`.
- **KV-cache quantization** — `kvCacheBits` (16/8/4, default 8) cuts
  KV-cache memory roughly in half on long prompts. Forwarded to the
  worker via `--kv-bits`; current value exposed in IPC `status`. See
  `docs/adr/0009-kv-cache-quantization.md`.
- **Streaming MLX inference** — tokens are pushed to the IPC client as
  they're generated.
- **`os_signpost`** — markers on hot paths for Instruments.
- **Boot-time recovery** — on startup the daemon reads `frozen.pids` and
  `SIGCONT`s anything left over from a previous run (in case the daemon
  was killed past its handler).
- **Plugin API (`LushaAccessor`)** — `OCRAccessor` and
  `FrontmostAppAccessor` ship in-tree; new accessors take roughly 30
  lines of code.

## Stack

- Swift 6 (strict concurrency + `ExistentialAny`). macOS 14+ (Sonoma).
- ScreenCaptureKit, Vision, MLX (`ml-explore/mlx-swift-lm`),
  HuggingFace Tokenizers.
- No Python — everything is native Swift.

## Project layout

```
Sources/
  FroggyDaemon/           — executable, the daemon hosting the IPC server
  FroggyMenuBar/          — SwiftUI MenuBarExtra client
  FroggyMLXWorker/        — child-process MLX inference worker
  VortexCore/             — actors: Vortex (freeze), MLXSupervisor,
                            Coordinator, ProcessClassifier,
                            FrozenPidsStore, IPC, FroggyConfig,
                            MemoryPressureMonitor, PageoutChain
  LushaBridge/            — VisionActor, ScreenStream, FrameDigest,
                            Redactor, ContextStore, LushaAccessor,
                            OCR/Frontmost
Tests/                    — 100+ tests, swift test --parallel
docs/adr/                 — architectural decision records
packaging/                — LaunchAgent .plist + entitlements + install recipe
.github/workflows/        — ci-selfhosted.yml (primary, self-hosted ARM64)
                            + ci.yml (hosted macos-14 fallback)
```

## Quick start

```sh
# Build everything (daemon + menubar + CLI + worker).
# `make build` wraps `swift build -c release` with a pre-build step that
# compiles `default.metallib` from the mlx-swift checkout. SwiftPM does not
# compile Metal shaders by default, so plain `swift build` produces a worker
# that crashes on the first MLX op — see ADR-0013 for the full story.
make build

# Run the daemon pointing at a local MLX model directory
.build/release/FroggyDaemon --model-path ~/models/qwen3-4b-4bit

# In another terminal, drive it through the froggy CLI:
swift run froggy status
swift run froggy gen --context "what app am I in right now?"
swift run froggy ctx --max 2000
swift run froggy load ~/models/qwen3-4b-4bit
swift run froggy snap frontmost

# Or talk to the JSON protocol directly:
echo '{"cmd":"status"}' \
    | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
echo '{"cmd":"generate","prompt":"hi","useContext":true,"maxTokens":50}' \
    | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
```

Or via the menubar app: `swift run FroggyMenuBar` — a frog icon in the
menu bar with status, model-path field, Load/Unload, recent context, and
Thaw all.

## Using Froggy as a memory-pressure daemon (no LLM)

If you already use Ollama, LM Studio, or another local LLM tool and just want
the memory-management subsystem, run the daemon without a model:

```sh
# No --model-path — daemon weighs ~50 MB, all freeze/thaw logic still runs.
.build/release/FroggyDaemon
```

`MemoryPressureMonitor` still watches `dispatch_source_memorypressure` and
freeze/thaws your configured apps. Configure which processes to freeze in
`config.json` — including the LLM tool's support apps (e.g., the Electron
shell that Ollama's web UI runs in) — so the *inference* process gets more
unified memory when pressure rises.

```json
{
  "freezeTier1BundleIds": ["com.spotify.client", "com.hnc.Discord"],
  "freezeTier2BundleIds": ["com.tinyspeck.slackmacgap", "notion.id"]
}
```

Screen capture and context window work as usual; `generate` / `loadModel`
commands return an error until a model is loaded via `froggy load <path>`.

## Context-aware generation

Pass `useContext: true` (either via `froggy gen --context …` or directly
in IPC) and the daemon pulls the latest sliding-window OCR from
`ContextStore`, runs it through the template in `PromptAugmenter`
(`docs/adr/0005-…`), and feeds it to the model as a system context
preamble. The model sees something like:

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

Without the flag the model sees only `prompt` (default is
`useContext=false`).

## Configuration

Lives at `~/Library/Application Support/Froggy/config.json` (mode `0600`).
All fields are optional and have defaults:

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

CLI flags (`--model-path`, `--capture-interval`) and environment variables
(`FROGGY_MODEL_PATH`, `FROGGY_CAPTURE_INTERVAL`) override values from the
file.

## IPC commands

| `cmd` | Parameters | Effect |
|---|---|---|
| `status` | — | `capturing` / `modelLoaded` / `modelPath` / `memoryPressure` / `frozen` / `snapshots` / `lastCaptureError` |
| `generate` | `prompt`, `maxTokens?`, `useContext?` | streaming generation. `useContext: true` mixes in recent screen context via `PromptAugmenter` |
| `context` | `maxChars?` | concatenated recent OCR snapshots up to the limit |
| `loadModel` | `path` | hot-swap the MLX model |
| `unloadModel` | — | unload + `MLX.Memory.clearCache()` |
| `accessors` | — | list of registered `LushaAccessor`s |
| `snapshot` | `accessor` | current snapshot from a single accessor |
| `freeze` | `pid` | `SIGSTOP` (via `ProcessClassifier`) |
| `thawAll` | — | `SIGCONT` everything currently frozen |
| `pressure` | — | `pressureLevel` / `tier1Frozen[]` / `tier2Frozen[]` / `secondsInLevel` |

## Installing as a LaunchAgent

See [`packaging/README.md`](packaging/README.md) — codesign + notarytool +
`launchctl bootstrap`. Outside of CI: requires an Apple Developer ID.

## Troubleshooting

`make logbundle` collects a unified-log archive filtered by
`subsystem == "com.froggychips.froggy"` into `./froggy.logarchive`,
suitable for attaching to bug reports. Pass `--last 1h` (or similar)
via `scripts/logbundle.sh` directly to limit the time range.

`make session-summary` collects a broader post-session bundle:
unified-log archive (last hour by default), SQLite freeze-events
dump from `freeze_stats.sqlite`, current `frozen.pids` and
`config.json` snapshots, system memory state (`vm_stat` /
`memory_pressure`), live IPC snapshots (`status` / `pressure` /
`accessors`) when the daemon is running, plus a `notes.md` template.
Each step is best-effort — missing pieces are listed in
`MANIFEST.txt`. Output is a tarball next to the working directory.
Pass `--last 4h --no-tar` via `scripts/session-summary.sh` for a
longer window or to keep the bundle as a directory.

## Documentation

The [`docs/adr/`](docs/adr/) directory captures the project's
architectural decisions: actors-over-locks, AF_UNIX-over-XPC,
Codable-config, Coordinator-pattern, reactive memory pressure, pageout
strategies, MLX subprocess isolation.

---
*Created for Apple Silicon. Built for Intelligence.*
