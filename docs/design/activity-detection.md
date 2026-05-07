# Design: Activity Detection for Freeze Confidence

| Field | Value |
|---|---|
| Status | Draft |
| Phase | Уровень 1.5 — Trust Governance |
| Depends on | Mem-1 (`MemoryPressureMonitor`), Mem-2 (`PageoutChain`) — both merged |
| Related | [`THESIS.md`](../THESIS.md), upcoming `freeze-confidence-model.md`, `explainability-menubar.md` |

## Why this exists

Per [`THESIS.md`](../THESIS.md), freeze without trust is a psychologically
hostile system. The single concrete failure mode that can destroy the
project is: **Froggy freezes Slack mid-call, the user's Zoom audio
breaks, the user uninstalls and tells everyone Froggy is "that frog
that broke my meeting"**. One incident is enough.

The mitigation is not "freeze less" — that collapses the thesis. The
mitigation is: **don't freeze a process that is doing something the
user actively cares about right now**. Activity detection is the input
layer that makes this possible.

This doc covers only signal collection and confidence scoring. The
*decision* logic (how Vortex consumes confidence to gate freeze
attempts) and the *explanation* logic (how the menubar presents what
happened and why) are separate documents.

## Goals

1. Produce a **per-PID activity confidence score** in `[0.0, 1.0]`
   where higher means "user actively cares about this process right
   now."
2. Sample at low cost — running every ~2 s without measurable RAM,
   CPU, or battery impact on an M1/M3 Air.
3. Be **observable**: every freeze decision must be traceable back to
   the individual signals that produced its confidence score.
4. Degrade gracefully if any signal source is unavailable (Apple
   removes a private API, AX permission revoked, etc.) — fall back to
   the remaining signals, never block the pipeline.
5. Keep all evaluation **local**. No data about activity leaves the
   machine.

## Non-goals

- **Not** a general-purpose process activity monitor. We score only
  candidates the freeze pipeline is about to consider.
- **Not** a learning system. No ML, no per-user training. A
  rules-based weighted scorer is sufficient and explainable.
- **Not** a replacement for `MemoryPressureMonitor`. Pressure decides
  *whether* freeze should happen; activity decides *which processes
  are eligible*.
- **Not** absolute correctness. Some false positives (refusing to
  freeze something that was actually idle) are acceptable. False
  negatives (freezing something the user cares about) are *not*.

## Where this sits in the stack

```
┌─────────────────────────────────────────────────────────────┐
│ MemoryPressureMonitor   →   "warning" / "critical" signal   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ VortexCoordinator.applyPolicy(level)                        │
│   for each candidate pid in tier-N:                         │
│     score = ActivityDetector.confidence(pid)  ◀── this doc  │
│     if score >= tier-threshold: skip freeze                 │
│     else: vortex.freeze(pid, reason: explanation)           │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Vortex.freeze(pid)  →  PageoutChain  →  FrozenPidsStore     │
└─────────────────────────────────────────────────────────────┘
```

`ActivityDetector` is a new actor in `VortexCore`, parallel to
`MemoryPressureMonitor`. Coordinator queries it synchronously per
candidate at the moment of freeze decision (cheap, < 5 ms target).

## Signals

Each signal returns a normalized contribution in `[0.0, 1.0]`. The
final confidence is a **weighted sum, not multiplication** — multiple
weak signals should be able to combine into a strong veto, and a single
strong signal alone is enough.

| ID | Signal | Source | API | Weight | Notes |
|----|--------|--------|-----|--------|-------|
| `frontmost` | Process is the frontmost app | `NSWorkspace` | public | 1.0 | Hard veto — frontmost is **never** frozen, regardless of other signals. |
| `audio-active` | Process owns an active audio I/O stream (mic input or output) | CoreAudio HAL | public | 0.9 | Catches Zoom, Teams, FaceTime, Discord voice, Music, Spotify. |
| `camera-active` | Process owns an active camera stream | CoreMediaIO HAL | public | 0.95 | Stronger than audio because video calls are higher-stakes. |
| `recent-input` | Time since last AX-observed user input on this app's windows | AX API | public, needs Accessibility permission | 0.7 (decay over 60 s) | Per-app keyboard/mouse activity. |
| `media-playing` | Process is the system "now playing" client | MediaRemote (private) | private | 0.6 | Spotify, Music, browser tabs with HTML5 audio. |
| `network-active` | High established TCP socket count + recent traffic | `proc_pidinfo` | public | 0.3 | Heuristic. Don't over-weight: Slack always has open sockets. |
| `fullscreen` | Process owns the current fullscreen-space window | Quartz Window Services | public | 0.5 | Don't freeze the browser presenting slides. |
| `recent-frontmost` | Was frontmost in the last N seconds | Internal tracking | — | 0.4 (decay over 30 s) | "User just switched away" should not trigger immediate freeze. |
| `cpu-burst` | Process used > X% CPU in the last 5 s | `proc_pidinfo` (rusage) | public | 0.2 | Weak signal — many things spin idly. |

### Weight calibration

The weights above are starting values. They are deliberately
**asymmetric**: signals that strongly correlate with "user cares" get
near-veto weights (audio/video), signals that correlate weakly (CPU,
network) are tie-breakers.

The aggregated confidence formula:

```
confidence = min(1.0, sum(signal_value * signal_weight))
```

Two design choices that may surprise:

1. **`frontmost` is implemented as a hard pre-check, not a weighted
   signal.** If the candidate is the frontmost process, return `1.0`
   immediately, skip everything else. This is for both correctness
   (any frontmost freeze is a bug) and speed (no need to sample other
   signals).

2. **No multiplicative damping.** A process with `audio-active` alone
   should fail-safe to "don't freeze" even if every other signal says
   "idle". This is the asymmetric-failure principle: false positives
   are cheap, false negatives are catastrophic.

## Confidence integration with freeze policy

Per-tier thresholds (initial values, tunable via config):

| Pressure level | Tier | Confidence threshold to skip freeze |
|---|---|---|
| `warning` | tier-1 | `>= 0.3` |
| `critical` | tier-1 | `>= 0.5` |
| `critical` | tier-2 | `>= 0.4` |

Reading: **under warning, even a moderately-active app gets skipped.
Under critical, only strongly-active apps get skipped.** This matches
the principle that critical pressure is genuine emergency where some
UX cost may be acceptable, but warning pressure should be
near-invisible to the user.

A separate config field `activityConfidenceOverride: [bundleId: Float]`
allows users to manually pin specific apps to higher thresholds — e.g.
"never freeze 1Password regardless of confidence." (Note: this is
distinct from `freezeBundleIds` exclusion — that prevents the candidate
from entering the freeze pipeline at all; this is a confidence
override.)

## API

```swift
public actor ActivityDetector {
    public init(
        signalSources: [ActivitySignalSource] = .defaults,
        clock: any Clock<Duration> = ContinuousClock()
    )

    /// Return a confidence score and a structured trace of how it was
    /// computed. The trace is the input to the explainability layer.
    public func confidence(forPid pid: pid_t) async -> ActivityConfidence
}

public struct ActivityConfidence: Sendable {
    public let pid: pid_t
    public let score: Float                  // 0.0 ... 1.0
    public let signals: [SignalContribution] // populated for explainability
    public let sampledAt: Date
}

public struct SignalContribution: Sendable {
    public let id: String          // "audio-active", "frontmost", etc.
    public let value: Float        // raw signal value, 0.0 ... 1.0
    public let weight: Float       // weight applied
    public let contribution: Float // value * weight, what hit the sum
}

public protocol ActivitySignalSource: Sendable {
    var id: String { get }
    var weight: Float { get }
    func sample(forPid pid: pid_t) async throws -> Float
}
```

Each signal source is its own type implementing `ActivitySignalSource`.
This is deliberately the same testability shape as `PageoutImpl` /
`MemoryPressureSource` — fakes substitute trivially in xctest.

## Sampling cost and concurrency

Target: **`confidence(forPid:)` returns in < 5 ms in the common case**.

Strategy:

- Fan out signals concurrently via `withTaskGroup`. Total wall-clock
  is `max(signals)`, not sum.
- Each signal source maintains its own internal cache where the data
  is system-wide (e.g. frontmost app changes once per second at most;
  the audio HAL state changes infrequently). The cache TTL is 500 ms.
- Per-PID lookups (CPU burst, network, AX input) are not cached —
  they're cheap and stale data here is dangerous.

If any single signal source exceeds a 50 ms timeout, it returns 0
(neutral) and logs a warning. The pipeline never blocks on a slow
signal.

## Failure modes

| Failure | Detection | Fallback |
|---|---|---|
| AX permission revoked at runtime | First sample returns error | `recent-input` signal returns 0, log once, continue |
| MediaRemote private API broken in future macOS | Symbol lookup fails | `media-playing` signal returns 0, log once, continue |
| Audio HAL query times out | 50 ms timeout | Signal returns 0, retry next sample |
| `proc_pidinfo` denied (sandboxed pid) | Errno EPERM | Signal returns 0, lookup is best-effort |
| Process exited between candidate selection and sampling | `kill -0` returns ESRCH | Return `confidence = 0.0` immediately, skip all signals |

The failure mode we **cannot tolerate**: a single broken signal
silently disabling all the others. Each signal is independently
isolated and failure-tolerant.

## Privacy considerations

Most signals are inherently per-PID and do not capture content. Two
exceptions:

- **`recent-input` via AX API** could in principle observe what the
  user is typing. We sample only *timestamps*, not events. The AX
  observer is configured to receive notifications, then immediately
  records `Date()` and discards the event payload. No keystroke, no
  click coordinate, ever leaves the actor.
- **MediaRemote** can return song titles and artwork URLs. We
  intentionally **do not call** any track-info APIs — only
  `MRMediaRemoteGetNowPlayingApplicationPID`. The signal is "there is
  *something* playing in process X," never "track Y is playing."

Both restrictions are testable: a unit test asserts that
`SignalContribution.id == "recent-input"` never carries any data
beyond the timestamp delta, and `media-playing` never logs anything
beyond a PID.

## What we explicitly do not detect (and why)

- **Idle screen time globally** (`CGEventSourceSecondsSinceLastEventType`
  is global, not per-app). Already implicitly captured by
  `recent-input` per-app and frontmost tracking.
- **Network bandwidth shape** (e.g. "high volume = active stream").
  `proc_pidinfo` gives us socket counts cheaply but per-second byte
  counts are expensive. Not worth it for the marginal signal.
- **Notification activity.** Apps generating notifications would be a
  decent signal but the API requires a Notification Center extension
  with separate entitlements. Defer until / unless we add one for
  another reason.

## Test plan

Unit:

- **Per-signal:** each `ActivitySignalSource` has a faked OS layer.
  Tests verify the value is mapped to the documented `[0.0, 1.0]`
  range, including edge cases (0 input, max input, missing data).
- **Aggregation:** `ActivityDetector` with a mix of fake sources;
  verify weighted sum, frontmost short-circuit, and that one slow
  source doesn't block the rest.
- **Decay:** `recent-input` and `recent-frontmost` decay correctly
  over time using an injected `Clock`.

Integration:

- **Real signals on real PIDs:** spawn a child process that takes
  audio (sox -n -d), verify `audio-active` flips to high confidence
  for that PID. Mark this skip-by-default behind
  `FROGGY_RUN_INTEGRATION_TESTS=1` (audio devices on CI are mocks).

End-to-end:

- **Freeze policy with confidence:** with a forced `.warning` pressure
  via `MemoryPressureSource` fake, simulate two candidate apps, one
  with high confidence (e.g. frontmost), verify it's skipped while
  the other is frozen.

Acceptance bar: confidence scoring is correct on **100% of unit
tests** and **all candidate freeze decisions in E2E are accompanied
by a non-empty `signals[]` trace** that justifies them.

## Implementation phasing

To avoid a 1500-line PR, the work is broken up:

1. **AD-1: Skeleton + frontmost + recent-frontmost.**
   - `ActivityDetector` actor, protocol, types.
   - Implements only the two simplest signals.
   - Wired into `VortexCoordinator` with conservative thresholds.
   - Acceptance: a freeze of the currently frontmost app is now
     impossible. This alone closes the most embarrassing failure mode.

2. **AD-2: Audio + camera signals.**
   - CoreAudio HAL and CoreMediaIO HAL queries.
   - Highest-confidence signals for the call-detection use case.
   - Acceptance: simulated call (sox/avfoundation child) cannot be
     frozen.

3. **AD-3: Recent-input via AX.**
   - AX observer setup, lifecycle (revocation, app launches/exits).
   - Permission flow in MenuBar — explicit "Froggy needs Accessibility
     permission to detect when you're typing in an app it might
     freeze."
   - Acceptance: typing into an app for 5 s prevents freeze for the
     next 60 s.

4. **AD-4: Remaining heuristics (media-playing, network, fullscreen,
   cpu-burst).**
   - Each is its own small PR if non-trivial.
   - Acceptance: aggregated confidence on real workload (Slack idle vs
     Slack with WebRTC call) shows clear separation.

5. **AD-5: Tunable thresholds + `activityConfidenceOverride` config.**

Phase boundary with explainability work: by the end of AD-2, the
confidence trace is already populated. Explainability menubar can
start consuming it independently, in parallel.

## Open questions

1. **Cost of AX observation at scale.** AX observers can be expensive
   if attached to many apps. May need to subscribe lazily — only attach
   to candidates currently being considered for freeze, detach when
   they're no longer candidates. Will benchmark in AD-3.
2. **CoreAudio HAL access without root.** Some `kAudioDevice*`
   properties may require elevated privileges to enumerate clients.
   Need to verify on a clean dev machine before committing to the
   audio-active signal as high-weight. If blocked, fall back to
   `lsof` on `/dev/audio*` (works without root).
3. **MediaRemote stability.** Private API; already at risk of removal.
   AD-4 should include feature-detect at startup and graceful degrade
   if symbols missing — same pattern as `memorystatus_control` in
   Mem-2.
4. **Threshold defaults.** 0.3 / 0.5 / 0.4 are first-pass numbers.
   Real values come from observing freeze rejection rate against a
   stable user workload over a week. Consider exposing these in the
   `freezeStats` IPC for easy tuning.

## Relation to THESIS

Per the qualitative-vs-quantitative test in
[`THESIS.md`](../THESIS.md): activity detection **enables a class of
capability**, not just improves an existing one. Without it, freeze is
a binary risk — either too aggressive (breaks calls) or too timid
(no value over Ollama). With it, freeze becomes a *governed* operation
that scales from gentle to aggressive based on real-time evidence of
user attention. That's a phase change, not a percentage improvement.

It is also the **first user-visible capability** of the trust layer:
"Froggy didn't freeze Slack because you have an active Zoom call" is
something no other tool says. Combined with the explainability menubar
(separate doc), this is the user-facing thing Froggy ships in
Уровень 1.5 — it is not "infrastructure before capability."
