# Architecture Decision Records

ADRs documenting non-obvious choices in Froggy's design. Add a new file
when:

* a decision affects more than one file/module,
* there's a real alternative that wasn't picked, and
* future-you would otherwise have to spelunk through `git blame` to recover
  the reasoning.

Format: short — Status / Context / Decision / Consequences / Alternatives.

## Index

* [0001 — Use Swift actors instead of explicit locks](0001-actors-over-locks.md)
* [0002 — Unix domain socket for IPC, not XPC](0002-unix-socket-over-xpc.md)
* [0003 — Codable JSON for persisted config, not TOML/YAML](0003-codable-json-config.md)
* [0004 — Vortex/MLX coupling lives in a Coordinator](0004-coordinator-vs-direct-coupling.md)
