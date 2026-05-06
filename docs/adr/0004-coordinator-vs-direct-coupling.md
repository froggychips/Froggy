# ADR 0004 — Vortex/MLX coupling lives in a Coordinator, not in either actor

* **Status:** Accepted (Phase 1)
* **Date:** 2026-05-06

## Context

The README's headline feature ("Dynamic RAM Recovery") requires that, before
loading a multi-GB MLX model, Froggy SIGSTOPs background apps to free unified
memory. We had two ways to wire this:

1. Have `MLXActor.loadModel(modelPath:)` know about `VortexActor` and call
   `freezeProcess` on a list of pids it gets from somewhere.
2. Keep `MLXActor` and `VortexActor` ignorant of each other and put the
   policy in a third actor — `VortexCoordinator`.

## Decision

Option 2. `VortexCoordinator` owns the policy: it enumerates running
applications by bundle ID (via `NSWorkspace`), freezes them, then awaits
`MLXActor.loadModel`. On failure it thaws everything it froze.

## Consequences

* **Pro:** `MLXActor` and `VortexActor` stay independently testable.
  `VortexActorTests` doesn't need an MLX model; `MLXActor` (when we add real
  inference tests) doesn't need to reason about process control.
* **Pro:** The set of pids frozen *for this load* is tracked separately from
  pids frozen for any other reason. `emergencyThaw()` only releases the set
  the coordinator owns plus the explicit ones the IPC handler froze, so we
  don't accidentally resume something a future feature wanted kept stopped.
* **Pro:** Policy is configurable (the bundle-id allowlist) without touching
  the actors that do the actual work.
* **Con:** One more layer to understand when reading the daemon. We mitigate
  with a small surface: `loadModel`, `unloadModel`, `emergencyThaw`,
  `generate` (proxy).

## Alternatives considered

* **Closure injection** into `MLXActor` (`onBeforeLoad: () async -> Void`).
  Lighter than a coordinator, but spreads coupling across the daemon's wiring
  code and makes failure paths harder to follow.
