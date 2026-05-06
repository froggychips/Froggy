# ADR 0005 — Prompt augmentation runs daemon-side, not client-side

* **Status:** Accepted (Phase 7)
* **Date:** 2026-05-06

## Context

Phase 7 added "context-aware generation" — a switch on the IPC `generate`
command that prepends recent OCR context to the user prompt before sending
it to the MLX model. We had two places to do this work:

1. **In each client.** MenuBar / CLI / a third-party script would call
   `client.context()` first, then `client.generate(prompt:)` with the
   context concatenated to their prompt.
2. **In the daemon.** Client sends `useContext: true`; daemon fetches
   `ContextStore.recentContext()` and stitches it through `PromptAugmenter`
   before invoking `MLXActor`.

## Decision

Option 2. The `IPCRequest.useContext: Bool?` flag is the entire
client-side surface. `DaemonIPCHandler.augmentedPrompt` does the wrapping
once, on the same actor that owns `ContextStore`.

## Consequences

* **Pro:** Every client gets context-augmentation for free. The CLI gets
  it via `froggy gen --context`, MenuBar via the existing prompt panel
  (just flip the flag), a Python script via `{"cmd":"generate", "useContext":true}`.
* **Pro:** No race between `client.context()` and `client.generate()`. The
  context the model sees is the snapshot at generation time, not whatever
  was current 50 ms ago when the client made its first call.
* **Pro:** The augmentation template is centralized — improving it
  improves every consumer. Today it's hardcoded in `PromptAugmenter.defaultTemplate`;
  in a later phase we can lift it into `FroggyConfig`.
* **Con:** Clients can't easily inspect what they ended up sending to the
  model. We can address this with an optional debug flag that echoes the
  full augmented prompt back in the response if anyone asks. For now: not
  needed.
* **Con:** Daemon now embeds a small chunk of "prompt template" policy.
  This is on a path toward more LLM-orchestration logic living daemon-side
  (system prompts, tool schemas, etc.). We accept that — that's exactly
  what an "AI orchestrator" daemon should do.

## Alternatives considered

* **Two-step API for explicit clients, augmented for default.** Rejected:
  doubles the surface area without adding meaningful capability.
* **Augment in `MLXActor.generate(prompt:)` itself.** Rejected: `MLXActor`
  doesn't and shouldn't know about `ContextStore` — that coupling is what
  `VortexCoordinator` (ADR 0004) was built to avoid. The IPC handler is
  the right joining layer.
