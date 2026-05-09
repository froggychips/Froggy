# Design — Meeting Transcription (Discord + Microphone)

* **Status:** Draft / sketch. Not adopted, not implemented.
* **Date:** 2026-05-09
* **Related:** ADR 0008 (subprocess isolation), ADR 0011 (validation gate),
  ADR 0009 (kvBits — reusing the same IPC pattern for the Audio worker).
* **Key prior art:**
  [`froggychips/interview-assistant`](https://github.com/froggychips/interview-assistant) —
  the author's own "non-functional but conceptual" prototype. It contains a
  **production-grade audio capture pipeline and a WhisperMLX stack** that, when
  ported into Froggy, will provide a ready-made skeleton rather than a green field.
  See the separate section [«Reuse from interview-assistant»](#reuse-from-interview-assistant)
  below — it outweighs many other points in this document.

## Context and motivation

The current Froggy solves a narrow problem — freezing processes under memory
pressure. It works, but it **doesn't address a single live task** in the
author's actual workday. What's needed is a minimal applied toolset on top of
the same machine, using already-connected resources (mlx-swift LLM, MCP
channels, Apple Silicon).

First applied use case:

> During Discord calls, tasks are handed out verbally and then duplicated into
> Jira as text. The goal is for Froggy to listen to the call, separate **"me"**
> from **"Discord"**, and produce text that's ready for Jira.

## MVP scope

* Capture two audio streams:
  * **mic** — the local microphone,
  * **discord** — Discord's application output as a **single** stream (no
    per-participant separation within the call).
* **Hybrid transcription:**
  * realtime preview during the call (fast model, latency ≤ 5 s),
  * batch finalization after the call ends (`large-v3` or equivalent).
* **Triple output:**
  1. Markdown file with two tracks + timestamps written to disk.
  2. LLM summary via the **existing** `FroggyMLXWorker`
     (action items, commitments, deadlines).
  3. Auto-draft in Jira via the
     [`claude.ai_Atlassian` MCP](https://github.com/cloudflare/mcp-server-atlassian)
     (`mcp__claude_ai_Atlassian__addCommentToJiraIssue` /
     `mcp__claude_ai_Atlassian__createJiraIssue`).

## MVP non-goals

* **Acoustic diarization of Discord participants.** Separating "me vs them" —
  yes; "colleague A vs colleague B within Discord" — no. The pyannote stack adds
  100–200 MB of model weight with real-world accuracy of 70–85 %; not worth it
  for the first iteration. If it turns out to be critical later, it can be added
  as a separate module (see roadmap).
* **Discord bot / Discord API.** Clean per-user voice streams via the bot API are
  a different stack (server-side permissions, OAuth, persistent bot instance). The
  MVP stays local-only.
* **Concurrent calls.** One listener active at a time.

## Architecture

```
FroggyDaemon
├── MLXSupervisor → FroggyMLXWorker          (LLM, existing)
├── VortexCoordinator                        (freeze, existing)
└── AudioListener (NEW)
    ├── CaptureCoordinator
    │   ├── mic stream    (AVAudioEngine)
    │   └── discord stream (SCK / Core Audio Tap)
    ├── TranscriberSupervisor
    │   └── FroggyAudioWorker (subprocess)   ← same pattern as MLX
    │       ├── WhisperKit instance: small/base (preview)
    │       └── WhisperKit instance: large-v3   (finalize)
    ├── SessionStore (transcripts to disk)
    └── PostProcessor
        ├── → FroggyMLXWorker (summary)
        └── → Atlassian MCP (Jira draft)
```

**Why a worker subprocess.** The same argument as in
[ADR 0008 — MLX subprocess isolation](../adr/0008-mlx-subprocess-isolation.md):
WhisperKit loads a Core ML model into unified memory. When a call ends, the model
must be fully unloaded — not "approximately." `FroggyAudioWorker` follows the same
IPC protocol as `FroggyMLXWorker` — load / unload / kill — and `unloadModel`
guarantees memory is returned to the kernel via subprocess termination.

**Why capture in the Daemon but transcription in the Worker.** Capture is
lightweight — Core Audio + SCK API, minimal RAM, a long-lived stream. Transcription
is heavy — ML inference. Splitting along "lightweight holds state, heavy lives in a
killable subprocess" repeats the already-working pattern.

## Stack choices

### Audio capture

| macOS version | API | Notes |
|---|---|---|
| 14.4+ | [Core Audio Tap (`CATapDescription`)](https://developer.apple.com/documentation/coreaudio/catapdescription) | Tap by `pid`/`bundleID`. Clean, native, no virtual device. Requires Screen Recording permission (Apple's design). |
| 13.0–14.3 | [`ScreenCaptureKit` audio](https://developer.apple.com/documentation/screencapturekit) with `SCContentFilter(.application:)` | Apple-recommended before the Tap API. Same permission. |
| < 13 | (BlackHole / Loopback) | Not supported. Froggy targets `.macOS(.v14)`, so Tap is already applicable. |

Microphone capture uses standard AVAudioEngine — nothing special.

**Decision:** start with SCK as the baseline (works on all 14+). If
Tap entitlements can be subscribed to cleanly, add the Tap fast-path.

### Transcription — WhisperMLX (not WhisperKit)

**Decision revised** after discovering interview-assistant. The author already uses
**WhisperMLX** (Whisper via mlx-swift) there, not WhisperKit. Relevant files:
[`WhisperMLX.swift` (57 KB)](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLX.swift),
[`WhisperMLXProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLXProvider.swift),
[`WhisperProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperProvider.swift).

Arguments for WhisperMLX:

1. **Single ML infrastructure.** Froggy already depends on `mlx-swift-lm` and
   `mlx-swift` via `FroggyMLXWorker`. WhisperMLX lives in the same ecosystem —
   one Metal shader domain model, one ADR 0013-style metallib pipeline, one
   version-update touchpoint.
2. **Precedent in interview-assistant.** The code is already written and ran on
   the same machine. WhisperKit would need fresh testing for permissions / Core ML
   compilation / model fetching.
3. **GPU arbitration.** interview-assistant includes `GPUResourceManager` and
   "GPU lock arbitration (Whisper vs Qwen)" in `ConversationOrchestrator`.
   Using WhisperKit would mean two different GPU lifecycles under one unified
   memory pool — contention is harder to control.

Alternatives considered and rejected:

* **WhisperKit** — Apple's Core ML stack, separate from mlx-swift. A fine choice
  for a greenfield project (Klee would use it), but we already have an MLX
  investment.
* **whisper.cpp** — functional, but C++ wrapping complicates the Swift 6 strict
  concurrency story.
* **Apple Speech (`SFSpeechRecognizer`)** — Apple-native, but with cloud fallback
  on older models, and Russian quality is noticeably worse than Whisper.

### LLM summary

`FroggyMLXWorker` already exists and loads an mlx-swift LLM. No additional
dependency is needed — send the transcript over the same IPC channel with a system
prompt of "extract action items / commitments / deadlines."

The prompt lives in a dedicated versioned file
`Sources/.../prompts/meeting-summary.txt` (edit the prompt → bench breaks → roll
back).

### Jira draft

Via the
[`claude.ai_Atlassian` MCP](https://docs.atlassian.com/) — connected in the
author's environment, visible in the current session (`mcp__claude_ai_Atlassian__*`
tools).

* `createJiraIssue` — when the call produces a new task.
* `addCommentToJiraIssue` — when there's an update to an existing issue
  (call → issue mapping required; see open issues).

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
        SessionStore (to disk, append-only WAV or Opus)
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

**Rationale for dual transcription (preview + finalize).** Running `large-v3`
in real time on an M3 won't achieve an acceptable real-time factor; `base` will,
but accuracy suffers — especially for Russian-English code-switching. A final pass
with `large` over the recorded WAV after the call compensates for this.

## Permissions story

The exact set of entitlements is **known** — from
[`InterviewAssistant.entitlements`](https://github.com/froggychips/interview-assistant/blob/main/InterviewAssistant.entitlements):

```xml
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.device.speech-recognition</key><true/>
<key>com.apple.security.screen-capture</key><true/>
```

Applicable to Froggy as-is:

* **`screen-capture`** — for SCK audio from Discord. Apple ties audio-only capture
  to Screen Recording, which makes the permission request feel odd to the user.
  This needs to be explained in the UI.
* **`speech-recognition`** — only needed if Apple Speech is used as a fallback.
  If WhisperMLX only → this can be omitted.
* **`network.client`** — for the Atlassian MCP / HuggingFace model downloads.
* **`files.user-selected.read-write`** — for save-as of markdown transcripts.
* **Microphone** — separately via `NSMicrophoneUsageDescription` in Info.plist
  (this is not an entitlement). TCC prompt on first launch.
* **(optional) Core Audio Tap** — on macOS 14.4+, `CATapDescription` runs under
  the same `screen-capture` entitlement; no new separate one is needed.

The project's current code signing configuration is debug. A production build
with these entitlements will require an actual developer certificate
(see [ADR 0012 — signing constraints honest doc](../adr/0012-signing-constraints-honest-doc.md)).

## Open issues / resolve before Phase 1

1. **Trigger.** What activates the listener?
   * Hotkey (toggle on/off).
   * Auto-detect Discord in frontmost / running apps + voice activity.
   * Menubar action.
   * CLI: `froggy listen --duration 1h`.
2. **Call → Jira issue mapping.** Where does the issue ID for a comment come from?
   * Calendar invite (Google Calendar MCP is already in the environment —
     pull the description / Jira link from it).
   * Manual: hotkey `cmd+J` → triggers an inline prompt "Jira ID?".
   * LLM-derived: the summary contains an explicit reference.
3. **Privacy.** Transcripts contain everything colleagues say.
   * Store locally, no sync (disable CloudDrive for the directory).
   * Option to "redact PII via LushaBridge `Redactor` before summary."
4. **Storage budget.** A one-hour call in Opus ≈ 30 MB; in WAV — 230 MB.
   After a month of active use — up to 30 GB. A retention policy is needed:
   "keep N days" / "keep only summary, delete raw."
5. **Model confidentiality.** WhisperKit — local. LLM — local
   (`FroggyMLXWorker`). Jira MCP — this is an **external service call** through
   Atlassian. Summary content is sent to their server. If calls contain NDA
   content, the user must be explicitly informed.

## Roadmap (phased)

### Phase 0 — verify feasibility (no changes to `Sources/`)

* A spike is unnecessary given the [interview-assistant prior art](#reuse-from-interview-assistant) —
  feasibility on M-series silicon was already confirmed by the author. Replaced by:
* **Audit pass of interview-assistant**: read `AudioService.swift`,
  `WhisperMLX.swift`, `ConversationOrchestrator.swift` in full; list what we're
  porting and what we're not. This note is a first pass; a second pass with
  specific line references is needed after the code freeze is lifted.
* **Verify interview-assistant build status.** The author said it "doesn't work."
  Understand exactly what's broken: build failure / runtime crash / TCC prompt not
  appearing / Whisper too slow. Without this, we risk inheriting the same blocker.

### Phase 1 — capture + batch transcription (after freeze is lifted)

* `AudioListener` actor in `VortexCore` (or a new module `LushaListener`
  alongside `LushaBridge`).
* `FroggyAudioWorker` subprocess with a single WhisperKit instance.
* CLI command `froggy listen` → writes to disk + transcript afterward.
* Markdown output. No Jira / summary yet.

### Phase 2 — preview + summary

* Second WhisperKit instance in the worker for realtime preview.
* Integration with `FroggyMLXWorker` for summary.
* Menubar item showing current state.

### Phase 3 — Jira integration

* Atlassian MCP call from the daemon (or from a CLI script).
* Calendar → Jira mapping (see open issue 2).

### Phase 4 (optional) — diarization

* pyannote or an alternative local diarization solution.
* Only if Phases 1–3 show that it's useful without this, and the author
  asks for it.

## Hard constraints

* Do not download models on the user's behalf at first-record time. Pre-cache in
  `~/.froggy/whisper-models/<id>/` via a menubar "Download model" action.
* Do not start the listener automatically without user confirmation.
  The privacy cost is too high.
* Never upload audio to the cloud. Ever. Local or nothing.
* Do not touch Discord process internals (memory inspection / pipe hooking).
  Public macOS APIs only.

---

## Reuse from interview-assistant

[`froggychips/interview-assistant`](https://github.com/froggychips/interview-assistant)
is a SwiftUI app for live technical interviews, written by the author as a
conceptual prototype. It's marked as "non-functional," but contains a fully
thought-out audio + transcription + LLM pipeline that is 70–80% reusable for
Froggy meeting transcription.

**The key benefit:** we don't build audio capture from scratch. We take the
ready-made components, discard what's specific to the interview use case
(overlay hint window, on-screen code OCR, intent detection for interview
questions), and what remains is a base pipeline that fits our use case perfectly.

### What ports nearly as-is

| File from interview-assistant | Size | Why we need it |
|---|---|---|
| [`AudioService.swift`](https://github.com/froggychips/interview-assistant/blob/main/AudioService.swift) | 97 KB | **The main prize.** Three capture strategies: `processTap(pid:)` (Core Audio Tap), `loopback(deviceName:)` (BlackHole + aggregate), `microphoneOnly`/`appPreferredInput`. Engine stall watchdog, fallback chains, signal telemetry, channel auto-detection. Production-grade. |
| [`WhisperMLX.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLX.swift) | 57 KB | MLX-based Whisper inference — our STT engine. |
| [`WhisperMLXProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/WhisperMLXProvider.swift) | ~6 KB | Provider abstraction — allows swapping the backend without rewriting callers. |
| [`VAD.swift`](https://github.com/froggychips/interview-assistant/blob/main/VAD.swift) + [`VADTests.swift`](https://github.com/froggychips/interview-assistant/blob/main/InterviewAssistantTests/VADTests.swift) | 4 KB + 9 KB | Voice activity detection — needed to avoid transcribing silence. Comes with tests. |
| [`SpeechNormalizer.swift`](https://github.com/froggychips/interview-assistant/blob/main/SpeechNormalizer.swift) | 6 KB | Post-processing of recognized text (number normalization, abbreviations, etc.). Comes with tests. |
| [`SpeechDetectionService.swift`](https://github.com/froggychips/interview-assistant/blob/main/SpeechDetectionService.swift) | 14 KB | Service layer for VAD-based event detection. |
| [`MemoryAwareRouter.swift`](https://github.com/froggychips/interview-assistant/blob/main/MemoryAwareRouter.swift) + [`MemoryManagement.swift`](https://github.com/froggychips/interview-assistant/blob/main/MemoryManagement.swift) | 9 KB + 12 KB | **Especially valuable:** routing decisions under memory pressure. Integrates naturally with Froggy's `MemoryPressureMonitor` — effectively the same mental model. |
| [`GPUResourceManager.swift`](https://github.com/froggychips/interview-assistant/blob/main/GPUResourceManager.swift) | 6 KB | **GPU lock arbitration between Whisper and LLM.** Critical if `FroggyMLXWorker` (Qwen) and WhisperMLX run simultaneously in Froggy — contention over unified memory / Metal queues. |
| [`KeychainSecretStore.swift`](https://github.com/froggychips/interview-assistant/blob/main/KeychainSecretStore.swift) | 2.5 KB | Storing API keys (Atlassian token etc.) in the Keychain. |
| [`InterviewAssistant.entitlements`](https://github.com/froggychips/interview-assistant/blob/main/InterviewAssistant.entitlements) | 435 B | See the [Permissions story](#permissions-story) section. |
| [`StructuredLogging.swift`](https://github.com/froggychips/interview-assistant/blob/main/StructuredLogging.swift) | 14 KB | Structured os.Logger wrappers. Froggy already has `os.Logger` over unified log — pull this only if interview-assistant has useful patterns; otherwise skip. |
| [`EventBuffer.swift`](https://github.com/froggychips/interview-assistant/blob/main/EventBuffer.swift) | 8 KB | Ring buffer for events — conceptually close to Froggy's `ContextStore`. |

### What ports with significant adaptation

| File | Why adaptation is needed |
|---|---|
| [`TranscriptionService.swift`](https://github.com/froggychips/interview-assistant/blob/main/TranscriptionService.swift) (32 KB) | Dual-stream orchestration logic; Froggy needs this rewritten for dual-stream (mic + Discord), while interview-assistant structures it for an interview pair (interviewer/candidate). |
| [`ConversationOrchestrator.swift`](https://github.com/froggychips/interview-assistant/blob/main/ConversationOrchestrator.swift) (21 KB) + tests | Turn tracking, GPU lock arbitration, echo confidence — the concepts port over, but the trigger logic in interview-assistant is tailored to "detected interview question → invoke AI." Our trigger is different (see open issue 1 in this document). |
| [`AudioSetupManager.swift`](https://github.com/froggychips/interview-assistant/blob/main/AudioSetupManager.swift) (25 KB) | Onboarding wizard for audio routing. The loopback / process tap selection logic is useful; the UI steps need to be rewritten for our UX. |
| [`MLXProvider.swift`](https://github.com/froggychips/interview-assistant/blob/main/MLXProvider.swift) (16 KB) | We already have our own `FroggyMLXWorker`. Compare and take only what we're missing (e.g. [KLEE-A..F optimizations](../peer-research/klee-mlx-optimizations.md) if interview-assistant applied them). |

### What we do NOT port (interview use case specifics)

* `OverlayWindow.swift`, `MainWindowController.swift`, `OnboardingStepViews.swift`,
  `ContentView.swift` (110 KB), `SettingsView.swift` (148 KB) — UI built for the
  interview overlay; Froggy has its own menubar.
* `ContentClassifier.swift` (OCR classifier for code/configs/logs) — interview-specific.
  Froggy already has `LushaBridge` for OCR.
* `CodeGhostWriter.swift`, `Humanizer.swift`, `SystemPromptBuilder.swift`,
  `Prompt.swift` — interview ghost-writer / hint generator.
* `SimulatorView.swift`, `SimulatorManager.swift`, `BenchmarkManager 2.swift` —
  interview simulator / dev tool. We have our own `bench/`.
* `OnboardingManager.swift`, `OnboardingWizardManager.swift` — interview-flow
  onboarding.
* `HotkeyManager.swift` — we'll need hotkeys too conceptually, but it's cleaner
  to write our own than to strip out interview-specific bindings.

### Echo detection — mandatory dependency

`AudioService.echoDetector` + the methods `isEchoLikely()`, `getEchoConfidence()`,
`updateEchoDetector(with rms:)` solve a **critical** problem:

> If the user listens to Discord through **speakers** (not headphones), the
> microphone captures Discord's output. Without echo detection, the mic stream
> transcript will duplicate the Discord stream with a delay.

In interview-assistant — 300 ms acoustic correlation between mic RMS and system
RMS. If the correlation exceeds the threshold → the mic buffer is considered echo
and is not sent to transcription.

This was **not mentioned** in the original design doc — it must be added to Phase 1
as a mandatory component, not optional.

### Questions remaining after the reuse audit

1. **Why is interview-assistant "non-functional"?** The author wrote that the
   prototype doesn't work. We need to understand exactly what's broken: build
   failure on current Xcode? A TCC prompt not appearing on macOS 15? WhisperMLX
   crashing on load? GPU contention under simultaneous load? Without this
   knowledge we risk inheriting the same blocker.
2. **What version of mlx-swift does interview-assistant use vs Froggy?**
   Compare both `Package.resolved` files — if interview-assistant is on an older
   mlx-swift, the port will require API adaptation.
3. **Are there working tests in interview-assistant?** The test file list
   (`InterviewAssistantTests/`) is substantial — 12 files, ~1,000 lines. If they
   pass on main, that's a strong signal that the code isn't "completely broken" —
   just that end-to-end integration was never finished.

---

## Sources

* **[`froggychips/interview-assistant`](https://github.com/froggychips/interview-assistant)** —
  the author's own prior art. The primary source of ready-made components
  (see [Reuse from interview-assistant](#reuse-from-interview-assistant)).
* [Apple — ScreenCaptureKit framework](https://developer.apple.com/documentation/screencapturekit)
* [Apple — `CATapDescription` (macOS 14.4+)](https://developer.apple.com/documentation/coreaudio/catapdescription)
* [WWDC24 — Capturing system audio with Core Audio taps](https://developer.apple.com/videos/play/wwdc2024/10145/)
* [Atlassian Remote MCP server](https://www.atlassian.com/platform/remote-mcp-server)
* [pyannote-audio — speaker diarization](https://github.com/pyannote/pyannote-audio)
  (for potential Phase 4)
* [WhisperKit — argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) —
  rejected alternative (see [Transcription](#transcription--whispermlx-not-whisperkit) section).
