# Журнал архитектурных решений (ADR)

ADR фиксируют неочевидные решения в дизайне Froggy. Добавляйте новый файл, когда:

* решение затрагивает более одного файла/модуля,
* есть реальная альтернатива, от которой отказались, и
* будущий «ты» иначе был бы вынужден spelunk'ать через `git blame`, чтобы восстановить логику.

Формат: краткий — Статус / Контекст / Решение / Последствия / Альтернативы.

## Индекс

* [0001 — Swift actors вместо явных блокировок](0001-actors-over-locks.md)
* [0002 — Unix domain socket для IPC, не XPC](0002-unix-socket-over-xpc.md)
* [0003 — Codable JSON для конфига, не TOML/YAML](0003-codable-json-config.md)
* [0004 — Связка Vortex/MLX живёт в Coordinator](0004-coordinator-vs-direct-coupling.md)
* [0005 — Аугментация prompt'а выполняется на стороне daemon'а](0005-prompt-augmentation-daemon-side.md)
* [0006 — Реактивный memory pressure handler](0006-reactive-memory-pressure.md)
* [0007 — Pageout-стратегии: machVM / jetsam / scratch](0007-pageout-strategies.md)
* [0008 — MLX-инференс в отдельном процессе](0008-mlx-subprocess-isolation.md)
* [0009 — KV-cache квантизация](0009-kv-cache-quantization.md)
* [0010 — Profile-guided freeze ranking (этап 1: телеметрия)](0010-profile-guided-freeze.md)
* [0011 — Уровень 2: код первым, design-doc вторым](0011-code-first-design-second-for-level-2.md)
* [0012 — Signing-constraints (honest doc)](0012-signing-constraints-honest-doc.md)
* [0013 — Metallib missing in SwiftPM release build](0013-metallib-missing-in-swiftpm-release.md)
* [0014 — Design-doc'и не гонятся вперёд имплементации](0014-design-docs-after-implementation.md)
* [0015 — Frontmost-veto, minimal scope (NSWorkspace only)](0015-frontmost-veto-minimal.md)
