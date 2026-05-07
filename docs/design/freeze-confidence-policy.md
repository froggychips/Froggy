# Design: Freeze Confidence Policy

| Field | Value |
|---|---|
| Status | Draft |
| Phase | Уровень 1.5 — Trust Governance |
| Depends on | [`activity-detection.md`](activity-detection.md), Mem-1 (`MemoryPressureMonitor`) |
| Related | [`THESIS.md`](../THESIS.md), upcoming [`explainability-menubar.md`](explainability-menubar.md) |

## Why this exists

[`activity-detection.md`](activity-detection.md) defines how Froggy
*knows* whether a process is being actively used. This document
defines how Froggy *acts* on that knowledge — the decision logic
sitting between `MemoryPressureMonitor` (which says "we need to free
memory") and `Vortex.freeze` (which actually does the freezing).

A pure threshold check on confidence is insufficient. The decision
needs four additional inputs:

1. **Cooldowns** — same app shouldn't be frozen twice in 30 seconds.
   That's not memory management, that's a chat-app on/off pulse.
2. **Freeze budgets** — no app is frozen more than X minutes per
   hour, regardless of pressure. Otherwise a backgrounded WebSocket
   app dies under sustained pressure.
3. **Max-duration watchdog** — even under permanent pressure, no
   freeze lasts longer than Y minutes without a forced thaw + re-evaluation.
4. **Per-app overrides** — user has final word: explicit allow-list,
   deny-list, custom thresholds.

Without these, freeze decisions are "correct" in the moment but
collectively produce a hostile UX: apps oscillate, websockets break,
notifications get lost. The **policy** is what turns moment-correct
freeze events into user-acceptable behavior over time.

## Goals

1. Take the activity confidence score and pressure level, produce a
   **freeze / skip / force-thaw** decision with a structured trace.
2. Enforce cooldowns and budgets *atomically* — no race window where
   a candidate sneaks past a budget check.
3. Persist enough state to survive daemon restart without losing
   credibility ("Slack just got force-thawed because daemon restarted
   and forgot it had hit budget").
4. Expose the entire decision context to
   [`explainability-menubar.md`](explainability-menubar.md) as a
   structured trace — never log free-form strings as primary record.
5. Be observable and tunable without a recompile. Thresholds, budgets,
   and overrides all live in `FroggyConfig`.

## Non-goals

- **Not** a learning system. Same as activity detection — rules-based,
  explainable, no ML.
- **Not** the place where individual signals are computed (that's
  activity detection).
- **Not** the place where explanations are rendered for humans (that's
  the menubar doc).
- **Not** a per-PID throttle. Freezes/cooldowns/budgets are tracked
  by **bundle id**, because PIDs change on restart and the user's
  perception is "Slack got frozen again" not "PID 2147 got frozen
  again."

## Where this sits in the stack

```
┌──────────────────────────────────────────────────────────────────┐
│ MemoryPressureMonitor → AsyncStream<MemoryPressureLevel>         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ FreezePolicyEngine.evaluate(level, candidate)  ◀── this doc      │
│                                                                  │
│   1. lookup overrides for candidate.bundleId                     │
│   2. ask ActivityDetector.confidence(forPid: candidate.pid)      │
│   3. check cooldown (state[bundleId].lastFreezeEnded)            │
│   4. check budget (state[bundleId].cumulativeFreezeThisHour)     │
│   5. compare confidence vs tier-threshold                        │
│   6. emit Decision { freeze | skip | thaw, reason, trace }       │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ VortexCoordinator → Vortex.freeze / Vortex.thaw                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ FreezePolicyEngine.recordOutcome(decision, result)               │
│   updates state[bundleId]: lastFreezeStarted, .ended,            │
│                            cumulative, currentlyFrozenSince      │
└──────────────────────────────────────────────────────────────────┘
```

`FreezePolicyEngine` is a new actor in `VortexCore`. It owns the
mutable state map `[bundleId: AppFreezeState]` and exposes evaluation
+ recording. The Coordinator is now thin — it reacts to pressure,
asks the policy engine per candidate, applies whatever the engine
returned.

## State model

```swift
struct AppFreezeState: Sendable {
    let bundleId: String
    var lastFreezeStarted: Date?
    var lastFreezeEnded: Date?
    var currentlyFrozenSince: Date?     // nil = not frozen now
    var cumulativeFreezeWindow: SlidingWindow<Duration> // last 60 min
    var consecutiveFreezeCount: Int      // resets to 0 after `restPeriod`
    var schemaVersion: Int               // for SQLite migrations
}

enum FreezeDecision: Sendable {
    case freeze(reason: FreezeReason, trace: DecisionTrace)
    case skip(reason: SkipReason, trace: DecisionTrace)
    case thaw(reason: ThawReason, trace: DecisionTrace)
    case noop  // candidate not eligible at all
}
```

The `cumulativeFreezeWindow` is a sliding 60-minute window, not an
hour-bucket. Hour-buckets create cliff-effects ("I was just under
budget at 10:59, now at 11:00 I have a fresh budget") that look like
bugs. Sliding window costs slightly more memory (one entry per freeze
event in the last hour) but is honest.

State is persisted to a SQLite file alongside `freeze_stats.sqlite`
from Mem-5 (or eventually merged into one schema, TBD). Restart
behavior:

- On startup: load all `AppFreezeState` rows. Anything with
  `currentlyFrozenSince != nil` was leftover from a crash → force-thaw
  via existing `frozen.pids` recovery mechanism, mark `lastFreezeEnded
  = now`.
- Cooldowns and cumulative windows survive correctly.

## Decision flow

```swift
func evaluate(
    level: MemoryPressureLevel,
    candidate: FreezeCandidate
) -> FreezeDecision {
    let trace = DecisionTrace(timestamp: clock.now, pid: candidate.pid)

    // 1. Eligibility — exclusion list always wins
    if config.freezeExclusion.contains(candidate.bundleId) {
        return .noop
    }

    // 2. Per-tier threshold lookup
    let threshold = config.thresholdFor(level: level, tier: candidate.tier)

    // 3. Override check before activity query
    if let override = config.confidenceOverrideFor(candidate.bundleId) {
        // Pinned to high confidence → never freeze under this policy
        if override >= threshold {
            return .skip(reason: .userOverride(override), trace: trace)
        }
        // Pinned to 0 → bypass activity detection entirely
        if override == 0.0 {
            // Still subject to cooldown/budget
            return checkCooldownAndBudget(...)
        }
    }

    // 4. Cooldown check
    if let lastEnded = state[bundleId]?.lastFreezeEnded {
        let elapsed = clock.now.timeIntervalSince(lastEnded)
        if elapsed < cooldownFor(candidate.bundleId) {
            return .skip(reason: .cooldown(remaining: ...), trace: trace)
        }
    }

    // 5. Budget check
    let usedThisHour = state[bundleId]?.cumulativeFreezeWindow.total ?? 0
    let budget = budgetFor(candidate.bundleId)
    if usedThisHour >= budget {
        return .skip(reason: .budgetExhausted(...), trace: trace)
    }

    // 6. Activity confidence
    let confidence = await activityDetector.confidence(forPid: candidate.pid)

    if confidence.score >= threshold {
        return .skip(reason: .activeUser(score: ...), trace: trace.merging(confidence))
    }

    return .freeze(reason: .pressurePolicy(...), trace: trace.merging(confidence))
}
```

The trace accumulates context as the function progresses. A `.skip`
returned at step 4 has only cooldown context; one returned at step 6
has full activity-signal trace. This is the input
[`explainability-menubar.md`](explainability-menubar.md) consumes.

## Auto-thaw triggers

A frozen app gets thawed by exactly one of these:

| Trigger | When | Behavior |
|---|---|---|
| Pressure normalized | `MemoryPressureMonitor` reports `.normal` for `gradualThawDelaySeconds` | Tier-2 immediately, tier-1 after delay (existing Mem-1 logic) |
| Budget exhausted while frozen | `cumulativeFreezeWindow` exceeds `budget` mid-freeze | Force thaw, ban from re-freeze for `restPeriod` (default 10 min) |
| Max duration exceeded | `currentlyFrozenSince + maxFreezeDuration` reached | Force thaw + log warning. Re-eligible after `cooldown`. |
| External activity detected | Foreground change to frozen app, audio session opens | Instant thaw + log critical warning ("we shouldn't have been frozen") |
| Explicit user thaw | IPC `thaw <pid>` or `thawAll` | Instant thaw, bypass all state |
| App exits | Process gone | Cleanup state, no thaw needed |

The "external activity detected" case is the **trust-canary**: if it
ever fires, our freeze decision was wrong. In production, the action
is thaw + warning. In tests, this should additionally fail loud
(assertion in debug builds) — it points to a confidence-scoring bug
in upstream activity detection.

## Defaults

```json
{
  "freezeBudget": {
    "default": "PT15M",
    "perBundle": {
      "com.tinyspeck.slackmacgap": "PT5M",
      "notion.id": "PT10M"
    }
  },
  "freezeCooldown": {
    "default": "PT60S",
    "perBundle": {}
  },
  "maxFreezeDuration": {
    "default": "PT15M",
    "perBundle": {}
  },
  "freezeRestPeriod": {
    "default": "PT10M"
  },
  "activityConfidenceOverride": {
    "com.1password.1password8": 1.0,
    "com.tinyspeck.slackmacgap-during-call": 1.0
  },
  "freezeExclusion": [
    "com.apple.WindowServer",
    "com.apple.dock"
  ]
}
```

(`PT15M` = ISO-8601 duration. Native Swift `Duration` codable
isn't ISO; will use a small custom decoder.)

Reading the defaults:

- **15 min budget per hour, 1 min cooldown** — under sustained
  pressure, an app gets ~15 min frozen + ~45 min active per hour.
  Long enough to free meaningful RAM, short enough that WebSocket
  reconnects don't lose state.
- **15 min max duration per single freeze** — even if pressure
  stays critical, no single freeze blocks the app for more than
  15 min before re-evaluation. App gets a chance to handle whatever
  it was doing.
- **10 min rest period after budget exhausted** — once an app hits
  its hourly budget, it's untouchable for 10 min. This is the
  trust-budget — Froggy literally won't try again.
- **`restPeriod < cooldown < maxDuration < budget`** — invariant
  preserved by config validation at startup.

## API

```swift
public actor FreezePolicyEngine {
    public init(
        config: FroggyConfig,
        activityDetector: any ActivityDetecting,
        clock: any Clock<Duration>,
        store: any FreezeStateStore
    )

    public func evaluate(
        level: MemoryPressureLevel,
        candidate: FreezeCandidate
    ) async -> FreezeDecision

    public func recordOutcome(
        _ decision: FreezeDecision,
        result: FreezeOutcome
    ) async

    public func liveDecisions() -> AsyncStream<FreezeDecision>
}

public protocol FreezeStateStore: Sendable {
    func load() async throws -> [String: AppFreezeState]
    func save(_ state: AppFreezeState) async throws
    func clear(bundleId: String) async throws
}
```

The `liveDecisions()` stream is what the menubar subscribes to. Every
decision (including `.noop` and `.skip`) is published — they're useful
for the user to see "Froggy considered Slack but skipped because
cooldown."

## Failure modes

| Failure | Detection | Behavior |
|---|---|---|
| `ActivityDetector.confidence` times out (> 100 ms) | Task timeout | `.skip(reason: .activitySignalUnavailable)` — fail-safe to no freeze |
| SQLite store write fails | Throws on `save()` | Decision still applied in-memory; warn log; retry on next decision |
| SQLite store load fails on startup | Throws on `load()` | Start with empty state; log critical; cooldowns/budgets reset (one-time degradation) |
| Clock skew (system time jumps backward) | Sliding window detects negative interval | Discard pre-jump entries from window, do not apply jump as "free budget" |
| Bundle id changes for same app (rebrand) | New entry, old stays | Acceptable — old state ages out of sliding window naturally |

Two principles reinforced everywhere: **fail closed (don't freeze on
ambiguity), persist what you can, never lose user trust over a
storage error**.

## Implementation phasing

| ID | Scope | Acceptance |
|---|---|---|
| FCP-1 | `FreezePolicyEngine` skeleton + threshold-based decision (consumes activity confidence, no budgets/cooldowns) | Coordinator delegates all freeze decisions to engine; trace populated; existing Mem-1 tier policy reproduced via thresholds |
| FCP-2 | Cooldowns | Repeated freeze of same app within cooldown returns `.skip(reason: .cooldown)` |
| FCP-3 | Sliding-window budget | App hitting budget mid-freeze gets force-thawed + rest period |
| FCP-4 | Max-duration watchdog | Frozen app force-thawed at maxDuration regardless of pressure |
| FCP-5 | Persistence (SQLite) + crash recovery | Daemon restart preserves cooldowns and budgets; orphaned freezes from crash recovered |
| FCP-6 | `liveDecisions()` IPC stream | Menubar can subscribe; structured trace flowing |
| FCP-7 | Per-app config overrides (exclusion, threshold pin, custom budget/cooldown) | All overrides in `FroggyConfig` working with config validation at startup |

FCP-1 and FCP-2 are the minimum viable trust governance. FCP-1 makes
freezes *responsive* to user activity; FCP-2 makes them *non-spammy*.
Everything else is refinement.

## Tests

Unit:

- **Threshold gate**: at each `MemoryPressureLevel × tier`, freezing
  is gated correctly by injected confidence values around the
  threshold (just below, exactly at, just above).
- **Cooldown**: replay sequence with injected clock —
  `freeze; thaw; immediate freeze attempt → skip; advance clock past
  cooldown; freeze attempt → freeze`.
- **Budget**: 30 small freezes summing to budget → next attempt
  forced to skip; advance clock 1 hr → budget refreshed.
- **Max duration**: long freeze under perma-pressure → force thaw at
  maxDuration; subsequent re-freeze respects cooldown.
- **Override precedence**: exclusion > confidence override >
  cooldown/budget > activity threshold.

Integration:

- Real `ActivityDetector` with stub signal sources, real clock; exercise
  end-to-end decision flow on a realistic pressure pattern.
- Crash recovery: write state to SQLite, kill engine mid-freeze, restart,
  verify recovered state matches.

Snapshot:

- Decision traces for canonical scenarios (cooldown skip, budget skip,
  active-user skip, pressure-driven freeze) — checked into the repo as
  expected JSON, regenerated on intentional change.

Acceptance: **every freeze in E2E tests has a non-empty trace**, and
**no test passes that violates the fail-closed principle** (e.g. a
timed-out activity query producing `.freeze` is a test failure).

## Open questions

1. **What about catastrophic pressure where every candidate scores
   above threshold?** Edge case: every candidate has high confidence,
   pressure stays critical, OOM looms. Options:
   - Override threshold (lower it dynamically until *some* candidate
     becomes eligible).
   - Trigger MLX worker `unloadModel` first, falling back to
     freezing only after the model itself is gone.
   - Surface a notification "Froggy can't free RAM without disrupting
     active work — close something or reduce model size."
   Need to pick one. Leaning toward option 2 (sacrifice the model
   before sacrificing user-active apps) but this is a thesis-level
   decision and warrants its own ADR before FCP-3.
2. **Cooldown vs budget — same scale or independent?** Currently
   independent. May want to make budget a function of cooldown
   (longer cooldown = more budget) to reduce config surface. Defer
   until real usage data.
3. **Should `liveDecisions()` be a protocol-typed AsyncStream or a
   concrete one?** Concrete is simpler. Protocol-typed allows menubar
   to substitute fakes for SwiftUI previews. Lean concrete unless
   preview becomes painful.
4. **Per-tier vs per-bundle thresholds.** Currently per-tier. Some
   bundles legitimately need per-bundle thresholds (e.g. a video
   editor that occasionally goes background mid-render). Defer.

## Relation to THESIS

Per [`THESIS.md`](../THESIS.md), the trust governance layer is
**non-negotiable** and operates as the **first user-visible
capability** of Уровень 1.5. Freeze confidence policy is the load-
bearing decision component of that layer:

- It is **qualitative** — without it, freeze is binary (always
  freeze under pressure / never freeze). With it, freeze becomes
  contextual, time-aware, and budget-aware.
- It is the **filter** that rejects "remove freeze entirely" critiques
  while still respecting "don't break user workflows." Both can be
  true simultaneously, and policy is the mechanism that makes them so.
- The trace it produces is **the input** to the explainability layer,
  which is what the user actually sees. Without policy traces,
  the menubar has nothing honest to show.

The combination *(activity detection → policy → explainability)* is
what THESIS calls "the trust layer is itself a capability." This
document is the middle term of that triple.
