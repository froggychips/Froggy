# Project History — From "Lusha" to Froggy

Froggy started as **Lusha**, a Python prototype written in March 2026
and rewritten from scratch in Swift two months later. This file
preserves the architectural lineage and the roadmap items that did not
make it into the current codebase but remain candidates for future work.

## Lineage (March 2026 → May 2026)

| Lusha (Python prototype) | Froggy (Swift) |
|---|---|
| `LushaCore` ("Eyes & Ears") | `Sources/LushaBridge`, `Sources/LushaExperimental` |
| `REASONING` ("Vortex / Logic") | `Sources/VortexCore` |
| `RAM_GUARD` ("Memory Sentinel") | `MemoryPressureMonitor` + ADR-0006 (reactive pressure) |
| `Harmonizer` (Python orchestrator, `subprocess.Popen`) | Swift coordinator + ADR-0008 (MLX subprocess isolation) |
| LM Studio / Ollama / Qwen / DeepSeek | MLX (on-device only — cloud fallback dropped) |
| `state.json` + `ai_voice_command.txt` | Unix-socket JSON IPC (ADR-0002) |

The names `Lusha` and `Vortex` survive in the current codebase as a
deliberate nod to the prototype.

## Carry-forward roadmap (not in current Froggy)

Three items from the prototype's master plan that did not land in the
Swift rewrite. Candidates for a future v2.

### Accessibility-based UI scanner

Use Apple Accessibility API to extract `{role, title, position, hierarchy}`
for the active window. Treat OCR and AX as redundant signals — when they
disagree, AX wins for clickable controls. Today Froggy is Vision-OCR-only.

### Overlay HUD

Draw hints directly on the screen via `NSPanel` (or Hammerspoon). Today
Froggy only surfaces text in the menu-bar popover; an overlay layer would
unlock "point at this button" UX.

### Teacher / Student distillation loop

Run a stronger model occasionally (DeepSeek-R1 class) to produce a
chain-of-thought "gold answer" for a given screen, store the
`(screen, AX, gold)` tuple in a local dataset, fine-tune the smaller
running model (Qwen-class) on it. Goal: a model that gets measurably
better on this user's workflows over time. Today Froggy just runs MLX
without a feedback loop.

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

The original prototype repo (`ai-screen-copilot-dev`) was archived
locally on 2026-05-08. Two files are kept for reference:

- `MASTER_PLAN.md` — the staged roadmap (phases 1–6).
- `LushaMCPServer.py` — the FastMCP server stub.
