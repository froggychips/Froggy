# Post-freeze TODO

Tracking list of `Sources/**`-touching work intentionally deferred during
the 2026-05-09 → 2026-05-16 code freeze. Each entry has a dedicated
GitHub issue with acceptance criteria, file paths, and effort estimate.

Sourced from the critique of the deep-research review of the Froggy
ecosystem (April–May 2026 iteration): items that are real gaps, not
out-of-scope advice. Cross-cutting recommendations that were rejected
(Erlang-style supervision trees, MLX worker pool, OpenTelemetry,
AXObserver replacement for NSWorkspace, encryption of local stores)
are *not* listed here — see PR history of ADR-0008 and ADR-0015 for
rationale.

## Wire protocol

- [ ] **[#57](https://github.com/froggychips/Froggy/issues/57) — `apiVersion` в wire-протоколах MLX / Audio / IPC.** Опциональное поле + version-mismatch warning. Защищает от ситуации «новый daemon + старый worker» при ручной замене бинаря или `mlxWorkerPath` override. Forward-compat через `decodeIfPresent`. Effort: 2-3 ч.

## Supervision

- [ ] **[#58](https://github.com/froggychips/Froggy/issues/58) — общий `WorkerSupervisor` protocol.** Дедупликация ~150-200 строк pipe-lifecycle (`waitForExit`/`OneShotResolver`/`ReadBridge`/graceful shutdown→SIGKILL) между `MLXSupervisor` и `AudioSupervisor`. **Не** Erlang tree (отвергнуто в ADR-0008). Effort: 6-8 ч.
- [ ] **[#64](https://github.com/froggychips/Froggy/issues/64) — State machine для `VortexCoordinator` lifecycle.** `enum CoordinatorState { idle, starting, ready, degraded(reason), recovering, stopping }`, exposed через IPC `status`, signpost-логирование transitions. Закрывает дыру «почему демон не реагирует, как диагностировать». Effort: 5-6 ч.

## Memory pressure + OCR pipeline

- [ ] **[#59](https://github.com/froggychips/Froggy/issues/59) — адаптивный `FramePacer` под уровень memory pressure.** `.warning` → x2 capture interval, `.critical` → x4 / пауза. Debounced возврат. Сейчас pacer статичен, OCR гоняется тем же темпом даже под красной зоной. Effort: 4-5 ч.
- [ ] **[#60](https://github.com/froggychips/Froggy/issues/60) — семантический OCR-diff поверх `FrameDigest`.** Пропускать `ContextStore.append`, если набор распознанных строк не изменился, даже если 32×32 pixel-fingerprint поплыл (анимация курсора, прогрессбары). Ожидаем 30-50% reduction в snapshot count на типичной сессии. Effort: 3-4 ч.
- [ ] **[#61](https://github.com/froggychips/Froggy/issues/61) — skip-list для динамических элементов в OCR.** Regex-pattern фильтр (часы, прогрессбары, percentage). User-extendable через `~/Library/Application Support/Froggy/ocr-skip-patterns.json`, по аналогии с Redactor. Effort: 4 ч.

## Security / privacy

- [ ] **[#62](https://github.com/froggychips/Froggy/issues/62) — IPC peer auth через `getpeereid`.** Помечено как hardening opportunity в `SECURITY.md`. Сейчас защита — только `chmod 0600` на socket-файле; любой процесс под этим юзером может слать команды. После `accept()` сверять uid, mismatch → close + log. Effort: 2-3 ч.
- [ ] **[#63](https://github.com/froggychips/Froggy/issues/63) — audit log freeze/unfreeze операций.** Structured JSON-line audit-trail с retention'ом (30 дней по аналогии с `FROGGY_SRE_MAX_AGE_DAYS`). Нужен для post-mortem «почему мой VS Code завис в субботу». Новая CLI команда `froggy audit`. Effort: 5-6 ч.

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

## Приоритезация

При снятии freeze'а (после 2026-05-16) разумный порядок:

1. **#57 apiVersion** — самый дешёвый и закрывает целую категорию проблем рассинхрона. Делать первым.
2. **#62 IPC peer auth** — security hardening, изолированный change, low risk.
3. **#58 WorkerSupervisor refactor** — освобождает codebase от копипасты перед добавлением новых supervised processes.
4. **#64 Coordinator state machine** — упрощает диагностику последующих фич.
5. **#63 Audit log** — пригождается всем кто читает audit'ом #58 и #64.
6. **#59 + #60 + #61** — OCR pipeline triplet. Делать вместе или последовательно. Самые «творческие» — оставить на конец, когда базовая дисциплина (#57–#64) на месте.

## История

- 2026-05-11 — список заведён, 8 issues открыты во время первой volna iter2 PR'ов.
- 2026-05-16 — ожидаемое окончание freeze'а; пункты переходят в активное TODO.
