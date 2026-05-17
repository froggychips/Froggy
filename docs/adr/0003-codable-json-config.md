# ADR 0003 — Codable JSON for persisted config, not TOML/YAML

* **Status:** Accepted (Phase 1)
* **Date:** 2026-05-06

## Context

Froggy needs persistent settings (model path, GPU memory cap, OCR interval,
freeze allowlist, IPC socket path, frame-diff threshold, context window size).

Common options:

1. **TOML** — pleasant to hand-edit; requires a third-party Swift parser
   (e.g. `dduan/TOMLDecoder`).
2. **YAML** — same hand-edit advantage, plus indentation footguns and a
   heavier parser.
3. **JSON** with `Codable` — verbose to hand-edit, zero dependencies, exactly
   round-trips the same struct that the rest of the daemon uses.

## Decision

`FroggyConfig: Codable, Sendable, Equatable` persisted as JSON at
`~/Library/Application Support/Froggy/config.json` with mode `0600`.
A custom `init(from:)` falls back to per-field defaults so a config written
by an older version still loads cleanly when new fields are added.

## Consequences

* **Pro:** No new SPM dependency; less surface area to vet for security.
* **Pro:** The same struct is the source of truth for tests, defaults, and
  on-disk format — one place to add a field.
* **Pro:** Forward-compatible: missing keys → defaults via `decodeIfPresent`.
* **Con:** Hand-editing JSON is mildly painful (no comments, strict commas).
  We ship `FroggyConfig.save()` and the MenuBar app to soften this.
* **Con:** No schema validation beyond Codable's type checks. Acceptable
  given the config is per-user and we control the producer.

## Alternatives considered

* **TOML.** Genuinely more pleasant for users to edit by hand; revisit if we
  ship a CLI-first installation flow without the MenuBar UI.
* **plist.** Native to macOS but worse to hand-edit than even JSON, and
  introduces XML or binary handling that Codable handles fine in JSON.

## Update — 2026-05-17 — wire-protocol versioning (issue #57)

The same Codable/forward-compat pattern is extended to the three wire
protocols between daemon and its peers: `MLXWorkerCommand`/`Event`,
`AudioWorkerCommand`/`Event`, and `IPCRequest`/`Response`. Each protocol
declares a namespace constant — `MLXWireVersion.current`,
`AudioWireVersion.current`, `IPCWireVersion.current` — and every struct
in that protocol carries an optional `apiVersion: Int?` field that
defaults to the constant at construction time.

### Pattern

```swift
public enum MLXWireVersion { public static let current: Int = 1 }

public struct MLXWorkerCommand: Codable, Sendable {
    // … existing fields …
    public var apiVersion: Int?
    public init(cmd: String, …, apiVersion: Int? = MLXWireVersion.current) { … }
}
```

### Why optional, not required

A required field would break the moment one peer is updated and the other
isn't — exactly the scenario the field exists to *detect*. With the field
optional, a legacy peer that never sets it is decoded with `apiVersion = nil`
and the receiver simply skips the mismatch check (silent path); a future
peer that bumps `current` to `2` is decoded fine on an old receiver because
unknown values pass through. Only on the rare case where both sides set the
field and the numbers differ do we log a warning.

### When to bump

Bump `current` only on **breaking** wire changes: removed fields, renamed
fields, changed semantics, new required commands. Pure additive changes
(new optional field, new command name) do **not** need a bump — Codable
forward-compat covers them via `decodeIfPresent`.

When you do bump, update **both** the producer and the consumer in the
same PR. The `testCurrentVersionsAreOne` anchor test in
`WireVersionTests` will fail and force you to acknowledge the bump.

### Mismatch handling

Per protocol, the consumer side keeps a once-per-version flag and logs a
single `os.Logger` warning when an unexpected `apiVersion` arrives. The
event/request is **not** rejected — Froggy still tries to do the work,
because the most likely cause is "user pointed `mlxWorkerPath` at a
slightly older binary during development" and dropping the message would
be a worse user experience than a warning + best-effort handling.

### Startup logging

`FroggyDaemon`, `FroggyMLXWorker` and `FroggyAudioWorker` each log their
own `current` at startup. When debugging a mismatch, grepping the log
for `wireVersion` from both processes is the fastest way to see who
expected what.
