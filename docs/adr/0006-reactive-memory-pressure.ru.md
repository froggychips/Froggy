# ADR 0006 — Реактивный memory pressure handler вместо preflight-freeze

* **Статус:** Принято (Mem-1)
* **Дата:** 2026-05-06

## Контекст

До Mem-1 `VortexCoordinator.loadModel(modelPath:)` морозил приложения из
`config.freezeBundleIds` ровно один раз — перед `mlx.loadModel`. Эта схема
плохо работает на 8 GB Mac:

* Если давление унифицированной памяти возникает **не** во время
  `loadModel` (например, идёт долгая генерация и compressor забит) — морозить
  некого, никто не реагирует.
* После выгрузки модели всё разморозилось — но если давление ещё держится,
  приложения тут же снова начинают eat memory.
* Один большой статический список `freezeBundleIds` смешивает «трогать
  смело» (Spotify) и «оживить дорого» (Slack).

## Решение

1. Новый actor `MemoryPressureMonitor` ловит `DispatchSource.makeMemoryPressureSource`
   и публикует `AsyncStream<MemoryPressureLevel>` (`.normal/.warning/.critical`).
2. Понижение уровня (warning→normal, critical→warning) проходит через
   debounce `pressureCooldownSeconds` (по умолчанию 60 c). Если за окно
   cooldown'а пришло обратное повышение — downgrade отменяется. Эскалация
   (повышение) — мгновенная.
3. `VortexCoordinator` подписывается на стрим. Политика:
   * `.warning` → `freezeTier1` (Spotify, Discord, Telegram, Dropbox).
   * `.critical` → `freezeTier1` + `freezeTier2` (Slack, Notion, Teams).
   * `.normal` → постепенная оттепель: tier-2 сразу, tier-1 — через
     `gradualThawDelaySeconds` (по умолчанию 10 c). Если до конца задержки
     пришёл upgrade — pending-thaw task отменяется.
4. `loadModel(path)` теперь делает `monitor.nudge(.warning, durationSeconds: 60)` —
   это виртуальное давление, поднимающее уровень не ниже `.warning` на
   минуту. Реальный путь срабатывания тот же; preflight ушёл, остался
   единый политический контур.
5. Источник давления абстрагирован в `protocol MemoryPressureSource` —
   тесты подменяют `DispatchMemoryPressureSource` на `FakeMemoryPressureSource`
   и эмитят сигналы вручную.

## Последствия

* **+** Реакция на любое реальное давление, не только во время `loadModel`.
* **+** Tier'ы разделены — лёгкие/тяжёлые приложения. На 8 GB у нас будет
  2-стадийная оборона.
* **+** Cooldown избегает «дёргания» при пограничных значениях давления —
  что в реальности случается часто, ядро шлёт сигналы пачками.
* **+** Тестируемость через protocol-injected source.
* **−** Coordinator теперь ведёт жизненный цикл (`startMonitoring`/
  `stopMonitoring`) и держит `Task` для подписки. Это +1 actor-state, но
  оправдано тем, что без него мы не поймаем давление между загрузками.
* **−** Старый `freezeBundleIds` deprecated, в Codable он теперь optional
  и маппится в tier-1 для обратной совместимости. Удалить через несколько
  фаз.

## Альтернативы

* **`vm_pressure_notify` напрямую через mach API.** Не даёт ничего сверх
  того, что DispatchSource уже выдаёт; добавил бы `task_for_pid`-style
  сложности с правами.
* **Свой polling `host_statistics64` с порогами.** Уже считаем `getMemoryPressure()`
  для status, но это менее быстрый канал и сам жжёт CPU.
* **Сохранить preflight-freeze.** Оставить как «всегда срабатывает на
  loadModel» — было бы дублирование политики в двух местах.
