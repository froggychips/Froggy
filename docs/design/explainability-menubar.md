# Design: Explainability MenuBar

| Field | Value |
|---|---|
| Status | Draft |
| Phase | Уровень 1.5 — Trust Governance |
| Depends on | [`activity-detection.md`](activity-detection.md), [`freeze-confidence-policy.md`](freeze-confidence-policy.md) |
| Related | [`THESIS.md`](../THESIS.md) |

## Why this exists

The trust layer doesn't exist if the user can't see it.

`ActivityDetector` and `FreezePolicyEngine` produce structured
decisions with rich traces. From the user's perspective, none of that
matters unless they can answer two questions in under five seconds:

- **"What is Froggy doing to my Mac right now?"**
- **"Why did Slack disappear / behave weirdly?"**

If these questions don't have honest, immediate, human-readable
answers, Froggy is — by [`THESIS.md`](../THESIS.md)'s definition —
psychologically hostile, regardless of how good the underlying
decision logic is.

This document covers the **presentation layer**. It contains zero
business logic. Decision-making lives upstream; this layer only
*shows* what happened and why.

## Goals

1. Surface every freeze decision in real time, with the *actual
   reason* (drawn from the `DecisionTrace`), not a templated
   approximation.
2. Lead with status; offer drill-down for the curious.
3. Make every shown number and timestamp *traceable* back to the
   underlying signal — no fabricated context, no rounded-away
   information that can't be reconstructed.
4. Be glanceable. The user shouldn't have to read paragraphs to
   understand current state. Headlines first, detail on demand.
5. Localizable. English first, structure that allows Russian
   translation without re-architecting.

## Non-goals

- **Not a control panel.** A separate freeze/thaw control surface
  outside the explanation context is out of scope (existing menubar
  already has Thaw All). However, **per-row contextual actions tied
  directly to the explanation** *are* in scope — see L3 below. The
  rule: an action is allowed inline if its meaning is unambiguous
  given the explanation right next to it ("thaw this one Slack you
  just told me about"). Anything more abstract goes elsewhere.
- **Not a metrics dashboard.** Pressure gauges and freed-RAM totals
  are useful context, but Froggy's job isn't to replace Activity
  Monitor.
- **Not a notification spammer.** System notifications are reserved
  for events the user actually needs to know *now* (see "Notification
  rules" below).
- **Not a log viewer.** Full structured logs go to `os_log` /
  Console; menubar shows a curated, human-friendly subset.

## Information architecture

Four layers, progressively more detail:

| Layer | Where | Content | When user sees it |
|---|---|---|---|
| **L1: Glance** | MenuBar icon + tooltip | Frog state (idle / managing / critical), frozen count | Always visible |
| **L2: Status** | Top of dropdown panel | "3 apps frozen, 1.2 GB recovered, pressure: warning (4 min)" | Click menubar icon |
| **L3: Detail** | Per-app row in dropdown | "Slack — frozen 18 min ago, ~600 MB freed, will retry thaw soon" | Hover or click on app |
| **L4: Trace** | Per-app expanded view | Full `DecisionTrace`: signals scored, thresholds, budget state | Click "why?" link in L3 |

The user pays attention proportional to context. L1 answers
"is Froggy doing anything weird" in 0.5 s. L2 answers "what's
happening" in 3 s. L3 answers "what about *this* specific app" in
5 s. L4 answers "explain in detail" for the curious or for bug
reports.

## L1: Glance state

Frog icon adapts to current Froggy state:

| State | Icon | Tooltip |
|---|---|---|
| Idle (no model loaded) | 🐸 (default) | "Froggy idle" |
| Active (model loaded, no freezes) | 🐸 (subtle pulse on generation) | "Model loaded, no apps frozen" |
| Managing (≥1 frozen, pressure normal/warning) | 🐸 (variant icon) | "2 apps frozen — managing pressure" |
| Critical (pressure critical, freezes active) | 🐸 (variant + accent color) | "3 apps frozen — memory critical" |
| Anomaly (freeze failed, decision-engine error) | 🐸 (warning badge) | "Issue with last freeze decision" |

Text-based variants (no emoji proliferation) — three SF Symbol
combinations max. The emoji 🐸 is strictly the app icon, not status
indicator.

## L2: Status header

Single line, always at top of dropdown:

```
[State summary]  ·  [Pressure]  ·  [Recovered]
```

Concrete:

```
3 apps frozen  ·  warning (4 min)  ·  ~1.2 GB recovered
```

When idle:

```
No apps frozen  ·  pressure: normal  ·  Froggy ready
```

When critical:

```
3 apps frozen  ·  CRITICAL (just now)  ·  ~1.2 GB recovered  ·  considering MLX unload
```

Rules:

- "Recovered" is **estimated**, not measured precisely. Use
  `~` prefix to mark estimation.
- Pressure-time is the duration the current pressure level has been
  held — "warning (4 min)" not "warning since 14:23."
- The optional 4th segment ("considering MLX unload") only appears
  during specific transition states. Never speculative —
  only shown when the policy engine has actually committed to that
  next action.

## L3: Per-app row

For each app currently frozen or recently considered:

```
┌─────────────────────────────────────────────────────────┐
│ Slack                       [why?] [thaw] [never freeze]│
│ Frozen 18 min ago · ~600 MB freed · thaw in ~4 min      │
└─────────────────────────────────────────────────────────┘
```

For an app *considered but skipped*:

```
┌─────────────────────────────────────────────────────────┐
│ Spotify                                        [why?]   │
│ Skipped 2 sec ago · keeping active                      │
└─────────────────────────────────────────────────────────┘
```

Skipped rows are visible only briefly (~30 s) — they answer "I
just felt my Mac get less responsive, what changed?" but don't
clutter long-term.

### Inline actions on frozen rows

Two per-row actions next to the `[why?]` link, only on rows
representing currently-frozen apps:

- **`[thaw]`** — immediate `SIGCONT` for *this specific app*,
  bypassing pressure-based auto-thaw timing. Existing IPC has
  `thawAll`; this requires a new command (see "API additions" below).
  The action does **not** add the app to any exclusion list — it's a
  one-shot override for this freeze, the next pressure event will
  reconsider the app normally.
- **`[never freeze]`** — adds the app's `bundleId` to
  `freezeExclusion` in `FroggyConfig` (defined in
  [`freeze-confidence-policy.md`](freeze-confidence-policy.md)) and
  triggers an immediate thaw. After this, the policy engine will
  refuse to consider this app at all. Confirmation toast: "Slack added
  to freeze exclusion list."

These actions are tied to the explanation context — the user is
seeing *why* an app is frozen, and the natural follow-up is "actually,
don't do this." Surfacing controls anywhere else is out of scope.

A third potential action — **`[lower threshold]`** which would write
to `activityConfidenceOverride` to make freeze less aggressive without
fully excluding — is deferred. It's harder to explain in one button-
label and the two coarser actions cover the realistic use cases.

Skipped rows have no inline actions: the user already has the outcome
they wanted (the app stayed running), no follow-up is needed.

## L4: Per-decision trace

When user clicks "why?", expand inline (not modal — modal disrupts
flow). Renders the `DecisionTrace` from
[`freeze-confidence-policy.md`](freeze-confidence-policy.md):

```
Slack — frozen 18 min ago

  Decision: freeze
  Pressure level: warning
  Tier: 1
  Threshold to skip: 0.30
  Confidence score: 0.12   (below threshold → eligible)

  Signals contributing to confidence:
    • frontmost            → no               (weight 1.0,  contrib 0.0)
    • audio-active         → no               (weight 0.9,  contrib 0.0)
    • camera-active        → no               (weight 0.95, contrib 0.0)
    • recent-input         → 87 sec ago       (weight 0.7,  contrib 0.05)
    • recent-frontmost     → 18 min ago       (weight 0.4,  contrib 0.0)
    • network-active       → 2 sockets idle   (weight 0.3,  contrib 0.07)
    • cpu-burst            → 0.3% in last 5s  (weight 0.2,  contrib 0.0)

  Budget check: 4 min used of 5 min/hour → eligible
  Cooldown check: 12 min since last freeze → eligible
  Override check: none

  Action taken: SIGSTOP + jetsam pageout
  Pageout result: succeeded (~600 MB freed via compressor)
  Will reconsider thaw in: 4 min (or earlier if pressure drops)
```

Renders straight from the trace JSON. **No string interpolation
that introduces information not present in the trace.** This is the
strict rule that prevents drift between explanation and reality:
if the trace says it, we display it; if the trace doesn't say it,
we don't make it up.

## Live updates

The menubar subscribes to `liveDecisions()` AsyncStream from the
policy engine (defined in
[`freeze-confidence-policy.md`](freeze-confidence-policy.md)) and
the existing pressure stream from `MemoryPressureMonitor`.

Strategy:

- L1 (icon) updates on every state transition — debounced to ≥ 200 ms
  to avoid flicker on rapid pressure changes.
- L2 (header) updates on every relevant event — pressure change,
  freeze, thaw, recovery estimate change.
- L3 (rows) animate in/out via SwiftUI transitions — frozen apps
  appear with subtle slide; skipped apps appear briefly then fade.
- L4 (trace) is fetched on demand; cached in-memory for the session.

Polling: **none**. Push-based via streams. If a stream disconnects
(daemon restart), show "reconnecting…" pill in the header for the
duration.

## Notification rules

Sparse and earned. The default is **silent operation** — the menubar
icon is the primary surface. System notifications fire only on:

| Event | Notification | Rationale |
|---|---|---|
| Pressure escalates to critical AND freezes haven't recovered enough | "Froggy: memory critical, freeing background apps" | User likely about to feel it; acknowledgment soothes |
| Freeze budget exhausted for ≥1 app while still under pressure | "Froggy: can't free more memory without disrupting active apps" | This is the rare actually-actionable state — user might want to manually close something |
| Freeze decision failed (e.g. pageout error) | "Froggy: couldn't freeze [App] — see menubar" | Debugging signal |
| Activity-canary triggered (we shouldn't have frozen this app) | "Froggy: thawed [App] because audio activity was detected" | Honest acknowledgment of upstream bug; preserves trust |

Not notified:

- Routine freezes / thaws (the default flow). They appear in the
  menubar but don't interrupt.
- Pressure changes between normal and warning. Too frequent to be
  signal.

## Generated text — language and tone

Three rules:

1. **Specific, not vague.** "Slack frozen — memory critical (6.8/8 GB
   used), no active call detected, background 18 min" beats "Slack
   has been suspended due to high memory usage."
2. **Honest about uncertainty.** "Spotify kept active — audio session
   open" is honest. "Spotify protected from freeze" is marketing.
3. **No jargon at the user-facing layer.** L1–L3 say "memory critical,"
   not "MEMORYSTATUS_PRESSURE_CRITICAL." L4 (trace) may use the technical
   names because L4 is for users debugging behavior.

Templates live in a single Swift file (`ExplanationFormatter.swift`)
keyed off `DecisionTrace` enum cases. Each template variant has a
test fixture: given trace `X`, generated text is `Y`. Snapshot tests
keep this honest.

## Localization

Phase 1 (with this design): English only. Templates in
`Localizable.strings` from day one — no hardcoded literals — so phase
2 is pure translation, not refactor.

Phase 2 candidate: Russian. The codebase has bilingual conventions
already (README split, comments in Russian). One additional
`Localizable.strings(ru)` file when there's appetite to maintain it.

Other languages: deferred until external contributor demand.

## API additions

### IPC

Read-only commands for the explanation surface:

```
decisions [--limit N]
  List recent decisions, newest first. Output: JSON array of
  DecisionTrace.

decision <id>
  Single decision by id. Output: JSON DecisionTrace.

decisionsLive
  Streaming. Pushes new DecisionTrace JSON lines as decisions
  emerge. Used by menubar; can be used by external tools.
```

State-mutating commands for the L3 inline actions:

```
thaw <pid>
  Immediate SIGCONT for a single pid. Distinct from existing
  thawAll. Validates pid is currently frozen by Froggy (refuses on
  unknown pid to prevent escalation through this command).

addExclusion <bundleId>
  Adds bundleId to FroggyConfig.freezeExclusion, persists to
  config.json, and triggers immediate thaw if the app is currently
  frozen. Idempotent. Used by [never freeze] action.

removeExclusion <bundleId>
  Inverse of addExclusion. Not exposed in menubar by default but
  needed for the config to be edit-able by humans through the same
  IPC surface (avoids forcing JSON editing).
```

The decisions endpoint is also publicly useful: bug reports become
easier when a user can attach `froggy decisions --limit 50 > log.json`
without revealing more than they intended.

The state-mutating endpoints respect the existing IPC trust model —
the Unix socket is filesystem-permissioned, not authenticated; same
trust boundary as the rest of the daemon.

### `FroggyMenuBar` views

```swift
struct FreezeStatusHeaderView: View      // L2
struct FrozenAppsListView: View          // L3
struct DecisionTraceView: View           // L4
struct LivePressureGauge: View           // L2 right segment
```

Each is independently previewable in SwiftUI Preview with fixture
data — fixtures live in `Tests/FroggyMenuBarTests/Fixtures/`.

## Failure modes

| Failure | Detection | Behavior |
|---|---|---|
| `decisionsLive` stream drops | Reader catches end-of-stream | "Reconnecting…" pill in header; auto-retry every 2 s |
| Decision missing fields (schema drift) | JSON decode partial | Show raw fields fallback in L4; degraded but visible |
| L4 generator can't render trace (unknown enum case) | Switch exhaustiveness | Display raw JSON as last resort + telemetry log |
| Daemon offline | Initial connect fails | Static "Daemon not running" state in menubar; offer "Start daemon" if PIDFile present |

The menubar must **never crash from bad daemon data**. It can show
degraded views, fallback to raw JSON, refuse to render — never crash.

## Test plan

Snapshot tests:

- For each `DecisionTrace` enum case, fixture `.json` + expected
  rendered text. Tests assert generation is bit-stable. Intentional
  copy changes regenerate fixtures explicitly.
- Coverage: at least one fixture per case in `FreezeReason`,
  `SkipReason`, `ThawReason`. Both English and (when added) Russian.

UI tests:

- SwiftUI Preview-driven smoke tests via the `swift-snapshot-testing`
  package. Each view rendered against fixtures, image diff in CI.
  Optional — only if maintenance cost is reasonable.

Accessibility:

- Every dynamic value has a VoiceOver label explaining content.
  L4 trace exposes signals as a properly structured list, not a
  flat text dump.
- Color is never the only carrier of state (icon variants do real
  work, accent color is supplementary).

Manual:

- Real-device test: trigger pressure manually (`memory_pressure -l warn`),
  observe menubar correctness; resolve pressure, observe thaw flow.
  Write up a one-page "manual test script" so this is repeatable.

## Implementation phasing

| ID | Scope | Acceptance |
|---|---|---|
| EXP-1 | IPC `decisions` + `decisionsLive` commands; in-memory ring buffer (last 100) | `froggy decisions --limit 5` shows real recent decisions; live stream emits on new ones |
| EXP-2 | L1 + L2 in MenuBar (icon states, status header) | Glance + status update live as pressure / freezes change |
| EXP-3 | L3 (per-app rows) | Frozen apps + recently-skipped apps render with summaries |
| EXP-4 | L4 (trace expansion) | "why?" link expands trace inline with full signal contributions |
| EXP-5 | Notification rules (4 events) | Critical pressure / budget exhausted / decision failed / canary triggered all surface as notifications |
| EXP-6 | `Localizable.strings` extraction + English copy review | All user-facing text routed through localization, English copy reviewed for tone |

EXP-1 + EXP-2 + EXP-3 are the minimum viable trust UX. EXP-4 is the
"power user / bug report" layer. EXP-5 covers the rare-but-important
events. EXP-6 is structural cleanup that should happen no later than
EXP-3 to avoid retrofit.

## Open questions

1. **Persisted decision history across restarts?** Currently the
   ring buffer is in-memory only. Pros of persistence: better bug
   reports, "what happened overnight" answer. Cons: privacy
   surface area (decisions reference bundle ids and timestamps).
   Lean toward: in-memory only by default, opt-in persistence flag
   in config.
2. **Should L1 icon variants use SF Symbols or stay with the frog
   emoji?** Frog emoji is the brand. SF Symbols are macOS-native
   and clearer. Possible compromise: frog emoji as base, SF Symbol
   badge overlay for state. Worth a designer's eye.
3. **Does L4 belong in the menubar at all?** It's dense; could live
   in a separate window invoked via "Open trace inspector." Trade-off:
   inline keeps everything in one place; separate window allows
   richer rendering. Lean toward inline for now (one place to look),
   reconsider after dogfood.
4. **What about long-form storytelling for "what happened in the
   last hour"?** A potential L5 would be a timeline view summarizing
   "Slack frozen 3 times, total 22 min, recovered ~1.8 GB" etc.
   Useful, but scope-creep risk. Defer until L1–L4 are real.

## Relation to THESIS

Per [`THESIS.md`](../THESIS.md), the trust layer is *itself* the
first user-visible capability of Уровень 1.5. This document is the
mechanism by which "trust governance" becomes something the user
*sees*, not just something the daemon *does*.

Specifically:

- It is **qualitative**: no other tool on macOS shows a per-app
  trace of *why* a process was throttled, with structured signal
  contributions. Activity Monitor shows *what*; Console shows
  *fragments*; this shows *why*.
- It is the **proof** that activity detection + policy were worth
  building. Without explainability, those two layers are a
  black box, and the user has no reason to trust them.
- It explicitly resists [`THESIS.md`](../THESIS.md)'s "infrastructure
  gravity trap": the menubar is a **shipped, user-facing feature**.
  The day EXP-3 lands, Уровень 1.5 has produced a thing the author
  uses every day and other people can immediately understand.

The triple `(activity detection → policy → explainability)` closes
here. After this, the substrate has produced its first capability
end-to-end. The next decision is not "more substrate" — it is
"which qualitative capability above this do we ship first."
