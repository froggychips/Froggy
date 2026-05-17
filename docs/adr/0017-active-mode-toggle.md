# ADR-0017: Active/Paused toggle for the daemon

Status: Accepted (2026-05-17)

## Context

`FroggyDaemon` runs as a per-user LaunchAgent and reacts to
`dispatch_source_memorypressure` events automatically. The default
configuration freezes tier-1 bundle IDs (Spotify, Discord, Telegram, …)
on `.warning` and tier-2 (Slack, Notion, Teams) on `.critical`. With the
daemon installed as a LaunchAgent, this happens **even when the user is
not actively driving Froggy** — the daemon sits in the background and
the freezing logic is permanently armed.

For a "personal-use scaffolding" project (see POSITIONING) this is too
aggressive a default. We want the freezing behaviour available, but we
want the user to be able to **see** that the daemon is active and to
**switch it off** with one click — without having to `launchctl bootout`
the agent from the terminal, and without leaving frozen pids behind
(any leftover SIGSTOP'd process would sit there until the next daemon
boot recovered it via `FrozenPidsStore`).

## Decision

Introduce a master switch `freezingEnabled` that gates the freeze
behaviour without shutting the daemon down.

- `freezingEnabled: Bool = true` lives in `FroggyConfig` (default `true`
  for backwards compatibility with existing `config.json` files).
- `VortexCoordinator` reads the initial value at init and exposes
  `isFreezingEnabled()` + `setFreezingEnabled(_:)`.
- When the flag flips to `false`, the coordinator calls `emergencyThaw`
  immediately (cancel pending thaw task, SIGCONT every tier-1/tier-2
  pid, clear in-memory tier sets).
- While the flag is `false`, `applyPolicy` and the `.appActivated`
  branch of `applyWorkspaceEvent` short-circuit. No `freezeTier` calls,
  no `thawTier` calls, no SIGSTOP, no SIGCONT.
- New IPC command `setFreezingEnabled {enabled: Bool}` is routed from
  the daemon to the coordinator and the new value is persisted into
  `config.json` so the choice survives a daemon restart.
- The daemon's startup path skips MLX model autoload when
  `config.freezingEnabled == false`. Idle mode is ~50 MB resident.
- The MenuBar app exposes a single `Active / Paused` toggle at the top
  of the popover. Toggling Off issues `setFreezingEnabled(false)` and,
  if a model is loaded, `unloadModel`, in that order. Toggling On only
  flips the flag — the model is not auto-loaded; the user clicks Load
  explicitly when they want it back.
- A second LaunchAgent plist (`com.froggychips.froggy-menubar.plist`)
  ships alongside the daemon plist so that the MenuBar is always
  running when the daemon is. Without this the only off-switch would
  be the terminal.

## Rationale

**Why a toggle, not a shutdown.** Hard-killing the daemon via
`launchctl bootout` works once, but it strips boot-recovery: any pid
left in `SIGSTOP` from a previous crash needs the daemon to come back
up and run `FrozenPidsStore.recover()`. A toggle that leaves the
daemon process alive keeps that safety net intact while still removing
the freeze behaviour from the user's experience.

**Why thaw on Off.** A pure flag flip without `emergencyThaw` would
leave already-frozen apps in `SIGSTOP` until the next pressure event
brought the level back to `.normal` and `applyPolicy` ran its thaw
path. With the flag off `applyPolicy` short-circuits, so those pids
would sit frozen forever. Forcing `emergencyThaw` on Off avoids that
trap.

**Why not auto-load on On.** When the user explicitly toggled Off,
their reason was almost certainly "I don't want Froggy doing things in
the background right now". Auto-loading the model on On would reopen
that surface as a side effect of the toggle. Requiring an explicit
Load click is two extra clicks but matches expectations: On = ready,
not On = running.

**Why a second LaunchAgent.** The daemon plist already lives in
`packaging/`. SwiftUI MenuBarExtra is a separate binary
(`FroggyMenuBar`) that does its own IPC to the daemon. Without an
agent for it, the user would have to launch the menubar manually
every session, which defeats the "one-click off-switch" goal — the
whole point of the toggle is that the user sees the daemon is active
without having to remember to bring up the UI. Running both agents in
parallel keeps each binary doing one job.

## Consequences

- Old clients that don't know about `setFreezingEnabled` keep working
  (default `true` means existing behaviour is preserved).
- Old `status` responses without `freezingEnabled` are interpreted as
  `true` by the MenuBar (legacy behaviour). The new MenuBar against an
  old daemon will show "Active" and the toggle will produce an
  `unknown cmd` error — by design, the user upgrades both bundles.
- The Audio capture path (`AudioSupervisor`) is **not** gated by this
  flag. A separate Mic/Audio toggle is a candidate follow-up; meeting
  capture is rare and explicit (`/listen`), so leaving it independent
  is the conservative default.
- `pressure` IPC command still emits pressure-level snapshots while
  Paused — observability is intact, only the actuator side is muted.

## Alternatives considered

1. **Shut the daemon down via `launchctl bootout` from the MenuBar.**
   Rejected: loses boot-recovery, requires `osascript` shell-out,
   leaves the user with no UI to bring Froggy back (no running daemon
   == no menubar status to poll).
2. **Make `freezingEnabled` controllable only through `config.json`.**
   Rejected: editing JSON to silence a background daemon is the
   opposite of an off-switch. We need a one-click path.
3. **Tie the toggle to `unloadModel` only.** Rejected: the loudest
   complaint is the freeze behaviour, not the RAM cost. Unloading
   alone would still SIGSTOP Spotify under pressure.
