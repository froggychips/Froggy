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
