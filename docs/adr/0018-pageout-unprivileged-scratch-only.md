# ADR 0018 — Unprivileged pageout is unreachable: `scratch` is the only working strategy

* **Status:** Accepted
* **Date:** 2026-09-19
* **Supersedes in part:** [`0007-pageout-strategies.md`](0007-pageout-strategies.md)
  (the default strategy and the promises made about `jetsam` / `machVM`)

## Context

ADR 0007 introduced three pageout strategies and made `jetsam` the default,
described as "works on any signature, no entitlements needed". A review on
2026-09-19 (Codex as second reviewer, then manual verification against the
macOS SDK headers and the XNU sources) established four facts:

1. **`VM_BEHAVIOR_PAGEOUT` is `11`, not `6`.** `Pageout.swift` used the
   literal `6`, which `mach/vm_behavior.h` defines as `VM_BEHAVIOR_FREE` —
   "free memory without write-back". With a successful `task_for_pid` the
   `machVM` strategy would therefore *discard* the contents of every writable
   region of the target process instead of paging them out. The same header
   marks `VM_BEHAVIOR_PAGEOUT` as "development only": a release kernel
   answers `KERN_INVALID_ARGUMENT` for every region, and the old code counted
   that as `.success` with zero pages hinted.
2. **`MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES` is `2`, not `1`.** The
   private header `bsd/sys/kern_memorystatus.h` defines `1` as
   `GET_PRIORITY_LIST`. The `jetsam` strategy has been issuing a *read*
   command with a 16-byte write buffer.
3. **`memorystatus_control` is privileged.** In
   `bsd/kern/kern_memorystatus.c` the syscall entry checks
   `kauth_cred_issuser() || IOCurrentTaskHasEntitlement("com.apple.private.memorystatus")`
   and otherwise returns `EPERM`. The only commands exempt from the check are
   `SET/GET_PROCESS_IS_FREEZABLE` and `GET_PROCESS_IS_FROZEN`. Fixing the
   command code therefore does **not** make `jetsam` reachable for a
   per-user LaunchAgent.
4. **Our own baseline already said so.** Every pressure snapshot in
   `bench/baseline.json` reports `jetsamAttempted: 1, jetsamFailed: 1,
   jetsamSucceeded: 0, scratchSucceeded: 1`. The chain has always fallen
   through to `scratch`. `TODO.md` had a validation gate for exactly this
   ("if `succeeded = 0` under jetsam — stop and investigate the substrate");
   the gate fired and development continued past it.

## Decision

* `PageoutChain` defaults to `.scratch`. `machVM` and `jetsam` stay in the
  code as explicit opt-ins for environments that actually have the
  privileges (root, SIP disabled, development kernel) and are documented as
  such. No "no entitlements needed" anywhere.
* Constants come from SDK symbols (`VM_BEHAVIOR_PAGEOUT`,
  `VM_REGION_BASIC_INFO_64`). The one private value without an SDK symbol
  (`MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES = 2`) is documented with its
  source.
* `MachVMPageoutImpl` returns `.failed` when **no** region accepted the
  behavior, so the chain falls through instead of reporting a hollow success.
  `JetsamPageoutImpl` reports `EPERM` with the reason spelled out.
* `FroggyConfig.pageoutStrategy` defaults to `.scratch` (changed in the
  daemon-hardening branch of the same review). Existing `config.json` files
  that pin `jetsam` keep working: the attempt fails fast with `EPERM` and
  falls back to `scratch`, exactly as it always did — only the counters and
  the log now say why.

## Consequences

* **Honest numbers.** `pageoutCounters` in the `pressure` IPC response stop
  showing a permanently failing strategy as the primary one.
* **What Froggy actually does under pressure** is `SIGSTOP` plus a 256 MB
  scratch allocation that nudges the compressor. That is a weaker claim than
  ADR 0007 made, and README now states it. Whether `scratch` is worth its own
  cost on an 8 GB machine is a question for `bench/`, not for this ADR.
* **`machVM` is safe to enable again** where `task_for_pid` works: it either
  pages out (development kernel) or fails cleanly (release kernel). It no
  longer frees pages behind the target's back.

## Alternatives considered

1. **Ship a privileged helper with `com.apple.private.memorystatus`.**
   Rejected: the entitlement is Apple-private and not grantable to third
   parties; a root helper contradicts the per-user LaunchAgent model
   (ADR 0012, `SECURITY.md`).
2. **Require SIP off for `machVM`.** Rejected as a default: it is a
   dev-machine setting, and `VM_BEHAVIOR_PAGEOUT` still needs a development
   kernel to do anything at all.
3. **Delete `machVM` and `jetsam`.** Not done: the code paths are small,
   exercised through `FakePageoutImpl`, and useful for anyone running Froggy
   on a development kernel. They are opt-in, not gone.
