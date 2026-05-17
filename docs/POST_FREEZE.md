# Post-freeze TODO — ✅ ЗАКРЫТ 2026-05-17

Все 7 issues из POST_FREEZE roadmap'а закрыты за один сессионный день
(2026-05-17). Документ оставлен как историческая запись + ссылки на
конкретные commit'ы для будущих археологов.

Эпики уехали в `v0.5.0` (большая часть) и `v0.5.1` (OCR-триплет):
- https://github.com/froggychips/Froggy/releases/tag/v0.5.0
- https://github.com/froggychips/Froggy/releases/tag/v0.5.1

Cross-cutting recommendations, которые были осознанно **отвергнуты**
(Erlang-style supervision trees, MLX worker pool, OpenTelemetry,
AXObserver replacement for NSWorkspace, encryption of local stores) —
не делались и не планируются; rationale в ADR-0008 и ADR-0015.

## Wire protocol

- [x] **[#57](https://github.com/froggychips/Froggy/issues/57) — `apiVersion` в wire-протоколах MLX / Audio / IPC.** Опциональное поле + version-mismatch warning. Защищает от ситуации «новый daemon + старый worker» при ручной замене бинаря или `mlxWorkerPath` override. Forward-compat через `decodeIfPresent`. _Closed: `c8fafc1` (effort 2.5ч)._

## Supervision

- [x] **[#58](https://github.com/froggychips/Froggy/issues/58) — общий `WorkerSupervisor` protocol.** Реализован как `WorkerProcessHost` (композиция, не protocol/inheritance). Дедуп −222 строки в MLX+Audio supervisor'ах. Audio worker теперь тоже регистрируется в `FrozenPidsStore.categoryWorker` для boot-recovery. _Closed: `67519ba` (effort 3ч)._
- [x] **[#64](https://github.com/froggychips/Froggy/issues/64) — State machine для `VortexCoordinator` lifecycle.** `enum CoordinatorState { idle, starting, ready, degraded(reason), recovering, stopping }`, exposed через IPC `status` + CLI `froggy status`, signpost POI events на каждом transition. Crash MLX worker → ready→degraded; loadModel из degraded → recovering→ready/degraded. _Closed: `40c05c4` (effort 2.5ч)._

## Memory pressure + OCR pipeline

- [x] **[#59](https://github.com/froggychips/Froggy/issues/59) — адаптивный `FramePacer` под уровень memory pressure.** `.warning` → ×2, `.critical` → ×4, multipliers конфигурируются. Debounce встроен в `MemoryPressureMonitor.cooldownSeconds`. _Closed: `e19c3e1` (effort 1.5ч)._
- [x] **[#60](https://github.com/froggychips/Froggy/issues/60) — семантический OCR-diff поверх `FrameDigest`.** `normalizeForSemanticDiff` (trim+sort+join) — если набор строк тот же, push в `ContextStore` пропускается. _Closed: `8d49506` (effort 1ч)._
- [x] **[#61](https://github.com/froggychips/Froggy/issues/61) — skip-list для динамических элементов в OCR.** `OCRSkipList` с default-патчами (HH:MM, N%, file sizes, versions, bare numeric), config-override + user-file. _Closed: `ed81b92` (effort 1.5ч)._

## Security / privacy

- [x] **[#62](https://github.com/froggychips/Froggy/issues/62) — IPC peer auth через `getpeereid`.** + `LOCAL_PEERPID` для audit-trail'а первой команды соединения. Same-uid trust boundary документирован в SECURITY.md как остающаяся слабость. _Closed: `e8ae5c2` (effort 1.5ч)._
- [x] **[#63](https://github.com/froggychips/Froggy/issues/63) — audit log freeze/unfreeze операций.** JSON-line writer в `~/Library/Application Support/Froggy/audit/audit-YYYY-MM-DD.log`, daily rotation, retention 30 дней. Новая CLI команда `froggy audit [--limit N] [--day YYYY-MM-DD]`. _Closed: `40c9bad` (effort 2.5ч)._

## Что НЕ в этом списке

Эти пункты — *out of scope* и фигурируют в обсуждении только для протокола. Сознательно отвергнуты:

- **Erlang-style supervision tree с MaxR/MaxT** — over-engineering для 2 worker-типов × 1 instance. См. ADR-0008 («следующий `loadModel` поднимет нового»).
- **Пул MLX-воркеров** — упирается в unified memory на 8GB Mac. Прямо отвергнуто в ADR-0008 («альтернативы»).
- **AXObserver вместо NSWorkspace** — TCC-prompt и расширение threat-model'и. Отвергнуто в ADR-0015.
- **OpenTelemetry / distributed tracing** — local-only macOS-демон, нет inter-service trace propagation, добавляет dep на OTel runtime ради 1 service.
- **Capability-routing / hot-swap в MCP** — нарушает Anthropic MCP-спеку (stateless server, single `protocolVersion`).
- **Encryption local store** — нечего шифровать, всё под TCC + `chmod 0600`.
- **cgroups для MLX worker'а** — на macOS их нет.
- **SwiftLint config** — `strictConcurrency + ExistentialAny` в `swiftSettings` сильнее (CONTRIBUTING это требует).

## История

- 2026-05-11 — список заведён, 7 issues открыты во время первой volna iter2 PR'ов.
- 2026-05-10 — freeze на `Sources/**` снят явным решением user'а (раньше чем планировалось).
- 2026-05-17 — все 7 issues закрыты за один день, выпущены v0.5.0 (1ef8e2f) и v0.5.1 (ec9c578).
  Faktический effort 14ч против оценённых 28-31ч (estimates закладывали human context-switching).

Приоритезация исполнения совпала с предложенной в этом документе:
#57 → #62 → #58 → #64 → #63 → #59 → (v0.5.0 release) → #60 → #61 → (v0.5.1 release).
