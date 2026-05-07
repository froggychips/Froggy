# Security policy

## Reporting

For security issues, please contact
[@froggychips](https://t.me/froggychips) on Telegram directly rather
than opening a public GitHub issue. A short message with reproduction
steps is enough; expect a reply within a few days. There is no bug
bounty — this is a personal project — but credit in release notes is
offered for substantive reports.

For non-security bugs, GitHub Issues is the right place.

## Threat model

Froggy is designed under the assumption that the **local user is
non-adversarial**. This is the only supported configuration.

In scope:

- Robustness against accidental misuse (badly-shaped IPC messages,
  malformed config files, unexpected process exits).
- Defence-in-depth for sensitive data: secret redaction *before* disk,
  per-app capture policy (when implemented), file modes `0600` for
  user data.
- Transparency over magic: every freeze decision is traceable; the
  user can see what Froggy did and why.

Out of scope:

- **Malicious local users.** Anyone with shell access on the same Mac
  can read `~/Library/Application Support/Froggy/`, write to the IPC
  socket, or replace the daemon binary. No protection is offered
  against this — it's the same trust model as any user-space macOS
  application.
- **Adversarial network.** The Unix socket has no network exposure by
  design. Do not bind it to a network interface; do not proxy it
  through SSH to untrusted hosts.
- **Compromised dependencies / supply chain.** `swift package` builds
  from public registries; supply-chain attestations are not in the
  current threat model. Lock files are committed; review diffs in
  `Package.resolved` when updating.
- **Side channels.** Memory pressure timing, freeze patterns, or
  generation latency may leak information about user behavior to a
  local attacker who can observe them. Not protected against.
- **Untrusted input to MLX.** Models are loaded from local disk paths
  the user provides. No validation of model contents — a malicious
  model file could in principle exploit MLX or the inference runtime.
  Don't load models from sources you don't trust.

## Sensitive surface areas

If you're auditing or doing security-aware refactors, these are the
parts to look at first:

- **`LushaBridge/Redactor.swift`** — the redaction step before
  context is written to disk. Regex-based, brittle by design (see
  `docs/POSITIONING.md`); review carefully before changing patterns.
- **`VortexCore/IPC.swift`** — the JSON-line protocol over Unix
  socket. No authentication; relies on filesystem permissions.
  Don't add commands that take arbitrary file paths without
  thinking about path traversal.
- **`VortexCore/Pageout.swift`** — uses `task_for_pid` and a private
  `memorystatus_control` symbol via `@_silgen_name`. Behaviour
  depends on macOS internals; see ADR 0007.
- **`Sources/FroggyMLXWorker/`** — child process. Parent-child trust
  is assumed; the worker is not sandboxed beyond the OS default.
- **`packaging/Froggy.entitlements`** — entitlements granted at
  signing time. Don't add new entitlements without an ADR.
- **`frozen.pids`** — file at `~/Library/Application Support/Froggy/`
  used for crash recovery. Mode `0600`. If tampered with, can cause
  Froggy to send `SIGCONT` to arbitrary PIDs at boot — but only
  against PIDs that pass `ProcessClassifier` checks.

## Privacy notes

- Screen captures are processed in memory and pass through `Redactor`
  before any persistence. Raw frames are never written to disk.
- The sliding context window holds the last N redacted snapshots in
  memory only.
- `freeze_stats.sqlite` (when Mem-5 lands) contains bundle IDs and
  timestamps but no content. File mode `0600`.
- Nothing is sent off-device by default. Cloud-routing, when added,
  will be opt-in per source with a separate threat-model review.

## Known limitations

- `Redactor` is regex-based and **incomplete by design**. It catches
  AWS keys, GitHub PATs, common token shapes, JWTs, Luhn-validated
  credit cards. It does **not** catch context-specific secrets
  (internal URLs, contact names, medical data, internal project
  codenames). Treat redaction as best-effort defence-in-depth, not
  a guarantee.
- `task_for_pid-allow` entitlement is required for the `machVM`
  pageout strategy to work on third-party processes. Apple grants
  this rarely; the default `jetsam` strategy works without it. See
  `packaging/README.md` and ADR 0007.
