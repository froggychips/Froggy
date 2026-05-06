# ADR 0001 — Use Swift actors instead of explicit locks

* **Status:** Accepted (Phase 0)
* **Date:** 2026-05-05

## Context

Froggy holds three pieces of mutable state that are read and written from many
async contexts:

* `VortexActor.suspendedPids` — the set of PIDs we have SIGSTOP-ed.
* `MLXActor.container` — the loaded MLX model (`ModelContainer`).
* `VisionActor.isCapturing` + `lastDigest` — the OCR loop state.

Two reasonable options existed:

1. Mark the holders as `class` and guard the state with `NSLock` / `os_unfair_lock`.
2. Make the holders `actor` types and let Swift 6's strict concurrency checker
   prove that no caller can race on the state.

## Decision

All three are `actor`s. Swift 6 strict concurrency is enabled on every target,
which makes shared-mutable-state mistakes a compile error rather than a runtime
data race.

## Consequences

* **Pro:** No `lock()`/`unlock()` boilerplate; impossible to forget. The
  compiler also forbids non-`Sendable` values from crossing the actor boundary,
  which caught one real bug (`ISO8601DateFormatter` as a static let — non-Sendable).
* **Pro:** Easy to add new mutators without thinking about lock ordering.
* **Con:** Every call into the actor is `async`, which forces our IPC handler
  and tests to be async too. We accept that — the rest of the stack is async
  anyway.
* **Con:** `NSWorkspace` and `NSPasteboard` are `MainActor`-isolated in Swift 6,
  so the `VortexCoordinator.pids(forBundleIds:)` and `FrontmostAppAccessor`
  have to hop to the main actor with `await MainActor.run`. This is fine for
  rare calls and produces no extra contention.

## Alternatives considered

* **Pure GCD queues.** Would let us stay synchronous-feeling, but loses the
  Swift 6 compile-time race detection.
* **Single global state actor.** Rejected — it would funnel all mutation
  through one queue and make the OCR cycle wait on MLX inference and vice
  versa.
