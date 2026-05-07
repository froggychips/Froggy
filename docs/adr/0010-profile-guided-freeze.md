# ADR 0010 — Profile-guided freeze ranking (этап 1: телеметрия)

* **Статус:** Accepted (Mem-5 этап 1)
* **Дата:** 2026-05-07

## Контекст

Tier-1/Tier-2 списки в `FroggyConfig` (Mem-1) — статические. Один и тот же
`Slack.app` на разных машинах может освобождать 800 MB или 50 MB —
зависит от количества чатов, кэша, recent-files. Дефолтный allowlist
угадывает «в среднем». Хочется, чтобы Froggy подстраивался под конкретного
пользователя.

Прежде чем строить ranking-overlay, нужны **данные**: для каждого
bundle_id — сколько он реально освобождает после `SIGSTOP + pageout`,
сколько занимает recovery после `SIGCONT`.

## Решение этапа 1

Только сбор телеметрии. Ranking-overlay (выбор tier'ов на основе медиан) —
**отдельный PR** через неделю-две, когда наберётся репрезентативная
выборка.

1. Новый actor `FreezeStatsStore` в `VortexCore`:
   - Persistent SQLite-БД в
     `~/Library/Application Support/Froggy/freeze_stats.sqlite` (mode 0600).
   - Через системный `sqlite3` C-API (`import SQLite3`) — без новых
     SwiftPM-зависимостей. macOS его всегда ships.
   - Schema v1: одна таблица `events` (id, ts, bundle_id, pid, rss_before,
     rss_after, pageout_strategy, recovery_ms) + индексы по bundle_id и ts.
   - Versioning через `PRAGMA user_version`. Будущие миграции — отдельные
     numbered блоки в `migrate()`.

2. Новый actor `FreezeRanker` в `VortexCore`:
   - На `freeze` (после успешного SIGSTOP+pageout) — снимает RSS через
     `proc_pid_rusage` (тонкая обёртка `ProcessRusage`), через 5 секунд
     снова, пишет дельту в БД.
   - На `thaw` — поллит pid с шагом 100 мс, фиксирует время до первого
     заметного изменения RSS (heuristic: |Δ| > 1 MB), пишет в БД как
     recovery_ms.
   - `rssReader` инжектируется — тесты подменяют на mock без реальных pids.

3. `VortexActor.init` принимает опциональный `ranker: FreezeRanker?`.
   `freezeProcess` после успешного SIGSTOP+pageout вызывает
   `ranker?.recordFreeze(pid, bundleId, strategy)`. `thawProcess` вызывает
   `recordThaw`. Если `ranker == nil` — телеметрия выключена, поведение
   остаётся прежним.

4. `FroggyConfig.freezeRankingEnabled: Bool = false`. На этапе 1 опт-ин:
   тот, кто хочет, включает в `config.json` и через ~неделю получает
   данные.

5. Новая IPC-команда `freezeStats` → топ-N bundle_id по медиане
   `rss_before − rss_after` за последние 7 дней + медиана `recovery_ms`.
   Используется для отладки и в будущем для построения overlay.

## Что НЕ делается на этапе 1

- **Ranking-overlay**: динамический выбор tier'ов на основе медиан. Это
  следующий PR. В нём будет:
  - bundle с медианой ≥ 500 MB → автоматически в tier-1, даже если в
    конфиге его нет.
  - bundle с медианой ≤ 200 MB → в tier-2.
  - bundle с recovery_ms > 2000 → понижается в приоритете (трогаем
    только при `.critical`).
- **Bundle-id парсинг через `CFBundleIdentifier`**: сейчас используем
  «псевдо-id» — имя `.app`-каталога из executable path. Для статистики
  достаточно; для overlay'а с user-edit'ом — нужно уточнить.

## Последствия

* **+** Без новых runtime-зависимостей: `import SQLite3` через
  `.linkedLibrary("sqlite3")` в `Package.swift`.
* **+** Сбор данных опт-ин и не меняет поведение freeze. Регрессий нет.
* **+** На реальных данных будем знать, какие приложения реально
  освобождают много RAM, а какие просто «в списке Slack потому что
  Slack».
* **−** SQLite C-API в Swift — много `OpaquePointer` и ручного
  bind/finalize. Пришлось обернуть в actor для thread-safety. Альтернатива
  с `SQLite.swift` дала бы красивее, но это новая зависимость.
* **−** Schema v1 запекает текущую структуру; добавление колонок потребует
  миграцию (ничего страшного, but plumbing нужен).
* **−** Расход на пользователя: одна запись в БД на каждый freeze + одна
  на thaw. ~50 байт / запись × 100 events / день = ~5 KB / день.
  Незначительно.

## Безопасность

- БД в `~/Library/Application Support/Froggy/`, mode 0600. Никаких
  путей пользователя кроме pid + bundle-id (имя .app). PII минимальна.
- bundle_id берётся из executable path, которому уже доверяет
  `ProcessClassifier` (default-deny). path-traversal невозможен — мы
  не открываем файлы по этому имени, только bind в SQL через
  параметризованный prepare/bind, не через string interpolation.
- На уничтожение демона БД остаётся. Очистка — пользователь руками либо
  через будущую IPC-команду `freezeStatsClear`.
