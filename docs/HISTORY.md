# Project History — From Lusha to VortexSentinel to Froggy

Froggy started as **Lusha**, a Python prototype written in March 2026.
A few days later the architecture was rewritten in Swift as
**VortexSentinelGUI**, which introduced the daemon + menu-bar split, a
multi-signal `RiskEngine`, and JSON-file IPC. Two months later the same
blueprint was re-implemented from scratch as Froggy, with MLX subprocess
isolation, reactive memory pressure, and Unix-socket IPC replacing the
file-based plumbing.

This file preserves the architectural lineage and the roadmap items that
did not make it into the current codebase but remain candidates for
future work.

## Lineage (March 2026 → May 2026)

| Stage | Project | What it added |
|---|---|---|
| 11–12 Mar | **Lusha** (Python prototype) | Concept of "AI screen copilot"; multi-engine orchestrator (`Harmonizer` + `subprocess.Popen`); names later re-used: `LushaCore`, `RAM_GUARD`, `REASONING` ("Vortex / Logic"). |
| 14–15 Mar | **VortexSentinelGUI** (Swift prototype) | Daemon + menu-bar split. JSON-file IPC (`state.json`, `timeline.json`, `snapshots.json`). Multi-signal `RiskEngine` for the freeze-or-keep decision (network connections via `lsof` + Accessibility API + audio assertions via `pmset`, score 0..1). `Vortex` promoted from a single engine name to the architecture-level prefix. |
| May → | **Froggy** (Swift, current) | MLX subprocess isolation (ADR-0008). Reactive memory pressure (ADR-0006). Pageout strategies (ADR-0007). Unix-socket JSON IPC (ADR-0002) replacing file-polling. Frontmost-veto (ADR-0015) as the minimalist successor to `RiskEngine`. |

### Component lineage

| Lusha → VortexSentinel → Froggy | Notes |
|---|---|
| `RAM_GUARD` → daemon `getMemoryUsage()` polling → `MemoryPressureMonitor` + ADR-0006 | Reactive `dispatch_source_memorypressure` replaced 5-second polling. |
| `REASONING / Vortex` → `VortexSentinelDaemon` / `VortexSentinelGUI` → `Sources/VortexCore` | `Vortex` moved from one engine name to the architecture-wide prefix. |
| `Harmonizer` (Python, `subprocess.Popen`) → daemon + GUI as separate processes → Swift coordinator + ADR-0008 (MLX subprocess isolation). | Each step preserved process isolation, refined the IPC. |
| `state.json` + `ai_voice_command.txt` (touch-file commands) → polling 4 JSONs every 2s → Unix-socket IPC (ADR-0002). | File-based IPC stopped scaling; switched to a real socket. |
| (none) → `RiskEngine` (network + AX + audio, weighted score 0..1) → frontmost-veto (ADR-0015). | Triple-signal collapsed to a single front-most-window check. |
| LM Studio / Ollama / Qwen / DeepSeek | (no LLM in VortexSentinel — that step was system-monitoring only) | MLX, on-device only, cloud fallback dropped. |

The names `Lusha` and `Vortex` survive in the current codebase as a
deliberate nod to the prototypes.

## Carry-forward roadmap (not in current Froggy)

Items from the prototypes that did not land in the Swift rewrite.
Candidates for a future v2.

### Accessibility-based UI scanner

Use Apple Accessibility API to extract `{role, title, position, hierarchy}`
for the active window. Treat OCR and AX as redundant signals — when they
disagree, AX wins for clickable controls. Today Froggy is Vision-OCR-only.

VortexSentinel already had partial AX usage in `RiskEngine`
(`AXUIElementCreateApplication`, `kAXMainWindowAttribute`) — that code is
a starting point if this lands.

### Overlay HUD

Draw hints directly on the screen via `NSPanel` (or Hammerspoon). Today
Froggy only surfaces text in the menu-bar popover; an overlay layer
would unlock "point at this button" UX.

### Teacher / Student distillation loop

Run a stronger model occasionally (DeepSeek-R1 class) to produce a
chain-of-thought "gold answer" for a given screen, store the
`(screen, AX, gold)` tuple in a local dataset, fine-tune the smaller
running model (Qwen-class) on it. Goal: a model that gets measurably
better on this user's workflows over time. Today Froggy just runs MLX
without a feedback loop.

### Multi-signal `RiskEngine` (revival)

Frontmost-veto (ADR-0015) is intentionally minimal. The earlier
VortexSentinel `RiskEngine` weighted three orthogonal signals — network
activity, AX interaction, audio playback — for a more nuanced
"is this app safe to freeze right now?" decision. If false-freezes
become a problem in practice, that scoring approach is the natural
extension.

## Alternate architecture worth re-considering

The prototype's `LushaMCPServer.py` (built on FastMCP) exposed Froggy as
an **MCP server**, not a client:

- `get_lusha_vision()` — return the current screen state as JSON.
- `send_command_to_lusha(command)` — push a text command into the
  daemon's reasoning loop.

Any MCP-aware client (Claude Desktop, Cursor, Gemini CLI) could then
read Froggy's screen context locally, without Froggy having to own a
tool ecosystem itself. Materially less work than building a tool
registry inside Froggy, and the integration surface is a published
protocol rather than a bespoke contract.

## Source archive

The prototype sources were archived locally on 2026-05-08:

- `~/Archive/ai-screen-copilot-dev/` — Lusha:
  - `MASTER_PLAN.md` — the staged roadmap (phases 1–6).
  - `LushaMCPServer.py` — the FastMCP server stub.
- `~/Archive/VortexSentinelGUI/` — full Swift sources for the
  VortexSentinelGUI prototype: daemon, GUI, models, `RiskEngine`,
  sample state JSONs.
