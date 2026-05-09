# ADR 0015 — Frontmost-veto, minimal scope (NSWorkspace only)

* **Статус:** Accepted
* **Дата:** 2026-05-07
* **Связано с:** [`0011-code-first-design-second-for-level-2.md`](0011-code-first-design-second-for-level-2.md)
  (gate Уровня 1.5 — AD-1), [`SECURITY.md`](../../SECURITY.md)
  (threat model, который **не** расширяется этим ADR — см. ниже)

## Контекст

`VortexCoordinator` морозит pid'ы по `bundleId`-allowlist'у при
`memoryPressure == .warning` (tier-1) и `.critical` (tier-1+tier-2).
Allowlist'ы конфигурируются глобально в config.json: `freezeTier1BundleIds`
включает heavy background-app'ы (Slack, Spotify, Telegram, …).

Failure mode, который этим ADR закрывается: пользователь активно
работает в одном из этих приложений (например, набирает сообщение в
Slack), система входит в `.warning`, coordinator морозит Slack по
allowlist'у — **прямо посередине набора текста**. UX-ущерб явный и
embarassing: программа, которая «следит за памятью», ломает интерактив
с приложением, в которое пользователь сейчас смотрит.

THESIS criterion #2 — «capability that cannot be reasonably achieved
without Froggy's architecture». До закрытия этой failure mode substrate
Уровня 1 формально работает, но subjectively неприемлем для daily use.
ADR 0011 эксплицитно блокирует Уровень 2 до AD-1+FCP-1+EXP-1 в main
именно потому, что без этих микро-инкрементов substrate не выдерживает
реального использования.

## Решение

**Pid frontmost-app никогда не попадает ни в tier-1, ни в tier-2 freeze,
даже если его bundleId в allowlist'е.**

Источник истины — `NSWorkspace.shared.frontmostApplication.processIdentifier`
+ subscription на `NSWorkspace.didActivateApplicationNotification`.
Реализовано через расширение `WorkspaceEvent`:

* Новый case `.frontmostChanged(pid: Int32?, bundleId: String?)` —
  эмитится из `RealWorkspaceEventSource` дополнительно к `.appActivated`
  (две разные семантики, см. комментарий в коде).
* Новый метод `WorkspaceEventSource.initialFrontmostPid()` — seed
  при старте координатора (без него первое окно между `startMonitoring`
  и первым `.frontmostChanged` event'ом мы морозили бы frontmost-app).
* `VortexCoordinator` кеширует `frontmostPid: Int32?` через event-stream
  (без polling'а, как в #38).
* `freezeTier(_:)` пропускает `pid == frontmostPid` с лог-строкой
  `"freeze pid=… vetoed: frontmost"`.
* Race-окно «pressure-event прилетел раньше frontmost-activate'а»
  закрывается дополнительной логикой в `applyWorkspaceEvent(.frontmostChanged)`:
  если новый frontmost pid уже заморожен в одном из tier'ов — он
  моментально оттаивается.

## Scope: minimal vs extended

**Этот ADR — minimal scope.** Сигнал «пользователь активно работает с app X»
аппроксимируется через «X в frontmost». Это покрывает ~95% реальных
случаев (typing в Slack, scrolling в Safari, code в Xcode, и т.д.).

**Альтернатива — extended scope:** прямой signal «пользователь печатает»
через Accessibility API:

* `AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, …)`
  + `AXObserverCreate` + подписка на `kAXValueChangedNotification` →
  получаем typing-veto: если в течение последних N секунд был edit
  focused text-field'а, не морозим тот pid вообще.
* Покрывает edge case'ы, в которых frontmost не меняется: например,
  фоновый Slack draft в плавающем mini-window, который не frontmost,
  но активно набирается (редко, но бывает).

**Extended scope отвергнут на этой итерации по трём причинам:**

1. **TCC Accessibility permission требует user prompt.** При первом
   старте daemon'а macOS показывает modal dialog «Froggy хочет
   контролировать ваш компьютер через accessibility features». Это
   ухудшает first-run UX и эмоционально звучит ровно так, как звучит —
   permission, который пользователю не очень хочется давать.
2. **Threat model в `SECURITY.md` придётся расширять.** Accessibility API
   позволяет читать содержимое **любых** UI-элементов на экране (текст
   в полях, заголовки окон, value labels). Daemon'у это формально не
   нужно — нам интересно только «было ли value-change event'a за
   последние N секунд», без чтения значения. Но permission даётся в
   полном объёме, и threat model должна это честно описывать. Это
   отдельный design pass, не in-scope для AD-1.
3. **Frontmost покрывает большинство практических случаев.** Если на
   практике 5% edge case'ов окажутся болезненными — открываем
   extended-PR с дополнительным AX-source'ом за дополнительной
   permission'ом. Сейчас это premature optimization.

Когда extended станет нужен — оформить отдельным ADR, обновить
`SECURITY.md`, добавить opt-in flag в config (по умолчанию выключен,
требует user opt-in после первого permission prompt'а).

## Альтернативы

* **Window-title heuristic** (smart-veto через `CGWindowListCopyWindowInfo`).
  Отвергнут: API возвращает значимо больше, чем нужно (титулы всех
  окон всех приложений) — это де-факто та же threat-surface, что и AX,
  без четкого upside по сравнению с frontmost'ом.
* **«Veto только tier-1, tier-2 морозим всегда»**. Полу-мера. Tier-2
  морозится в `.critical`, и frontmost-app в tier-2 allowlist'е
  (например, Spotify в фоне на критическом давлении) freeze посреди
  активного использования всё равно пользователю ущербен. Veto должен
  быть на оба tier'а.
* **«Уведомлять пользователя о grace-period перед freeze'ом frontmost'а»**.
  Слишком интерактивно для memory-pressure response loop'а — pressure
  events могут идти сериями по несколько раз в секунду, и сериал
  notification'ов ужасен. Если хочется такого UX — оно уровень MenuBar
  explainability (отдельный design-doc, см. `docs/design/explainability-menubar.md`).
* **Veto-пиксель: морозить frontmost, но с бо́льшим cooldown'ом**.
  Слишком хрупко: если cooldown слишком короткий — failure mode
  возвращается, если слишком длинный — теряем effective freeze'ы. Hard
  veto проще и predictable.

## Последствия

**Плюсы:**

* Закрывается embarassing failure mode без TCC permission prompt'а →
  first-run UX остаётся минималистичным.
* Threat model `SECURITY.md` не расширяется → review surface AD-1 PR'а
  узкий.
* Реализация — thin diff в существующих компонентах (`WorkspaceEventSource`
  + `VortexCoordinator`), без новых targets/файлов в Sources.
* Race-окно «pressure прилетел до frontmost-event'а» закрыто mid-freeze
  thaw'ом — если frontmost меняется во время freeze cycle, новый
  frontmost моментально оттаивается.

**Минусы:**

* 5% случаев, где frontmost не отражает activity, остаются непокрытыми.
  Если на практике user сообщит — открываем extended.
* Дополнительная нагрузка на `WorkspaceEventSource` (один extra event
  на каждое переключение фокуса). Cost ничтожный — `NSWorkspace`
  notifications достаточно дешёвые.

## Что разблокирует

После merge'а AD-1 (этого) + FCP-1 (frame-cycle pacing, parallel PR) +
EXP-1 (experimental accessors) в main — **только тогда** открывается
дизайн-этап Уровня 2 (см. ADR 0011). До тех пор не открывать voice/VLM/
persona/Takeout-ingest проектные обсуждения.
