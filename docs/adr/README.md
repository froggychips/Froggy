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
* [0005 — Prompt augmentation runs daemon-side](0005-prompt-augmentation-daemon-side.md)
* [0006 — Реактивный memory pressure handler](0006-reactive-memory-pressure.md)
* [0007 — Pageout-стратегии: machVM / jetsam / scratch](0007-pageout-strategies.md)
* [0008 — MLX-инференс в отдельном процессе](0008-mlx-subprocess-isolation.md)
* [0009 — KV-cache квантизация](0009-kv-cache-quantization.md)
* [0010 — Profile-guided freeze ranking (этап 1: телеметрия)](0010-profile-guided-freeze.md)
* [0011 — Уровень 2: код первым, design-doc вторым](0011-code-first-design-second-for-level-2.md)
