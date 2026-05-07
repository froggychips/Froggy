# bench/

Snapshot'ы `/froggy-bench` для сравнения «до vs после» mem-серий и
будущих оптимизаций. См. ADR 0011 — `bench/baseline.json` обязателен
до старта Уровня 1.5 (AD-1 / FCP-1 / EXP-1).

## Файлы

* **`baseline.json`** — массив snapshot'ов. Каждый объект — один прогон
  `bench/run.sh --save` с автоопределением сценария
  (`idle` / `model-loaded` / `under-pressure`). Цель — иметь все три
  сценария до начала AD-1.
* **`run.sh`** — скрипт сбора. Вызывается из репо-root или из любого
  worktree, sock-путь по умолчанию `~/Library/Application Support/Froggy/froggy.sock`.

## Как добить три сценария

С build'нутыми release-бинарями (`swift build -c release`):

```sh
# 1. idle — daemon без модели
./.build/release/FroggyDaemon &
sleep 5
bench/run.sh --save
kill %1

# 2. model-loaded — нужна локальная модель в формате MLX
./.build/release/FroggyDaemon --model-path ~/models/qwen3-4b-4bit &
sleep 30   # дать worker'у догрузить веса
bench/run.sh --save
kill %1

# 3. under-pressure — нужно реальное давление на unified memory
./.build/release/FroggyDaemon --model-path ~/models/qwen3-4b-4bit &
# вручную: открыть Chrome с YouTube + Xcode build чего-нибудь крупного,
# подождать пока memory_pressure вернёт "warn" или "critical"
bench/run.sh --save
kill %1
```

## Что читать в результате

`baseline.json` — массив. Каждый snapshot:

| поле | что |
|---|---|
| `scenario` | `idle` / `model-loaded` / `under-pressure` |
| `daemon_rss_kb` | RSS демона. Идеал idle: ~50 MB; model-loaded без worker'а — те же ~50 MB (peak уехал в worker). |
| `worker_rss_kb` | RSS worker'а. Зависит от модели; для 4-bit 4B ожидается ~3 GB. |
| `ttft_ms` | time-to-first-token. Только при `model-loaded`. |
| `vm_stat_raw` | сырой `vm_stat`. Смотреть `compressed`, `pages free`, `pages active`. |
| `froggy_pressure` | сырой ответ `pressure`. Смотреть `pageoutCounters` — реально ли pageout что-то делает. |

## Что считать «разумным»

В рамках THESIS criterion #2 — substrate должен дать выигрыш, который
без него не получишь. Конкретные ожидания (см. ADR 0011 § «Validation
gate»):

* `daemon_rss_kb` без модели ≤ 70 MB (Mem-3 убрала MLX из main process).
* После `unloadModel` `worker_rss_kb` → null **и** общий RSS возвращается
  к idle ± 50 MB.
* В `under-pressure` сценарии `froggy_pressure.pageoutCounters.jetsamSucceeded`
  ≥ 1 (jetsam реально срабатывает на твоей машине). Если 0 — Mem-2
  работает только на бумаге.
* `secondsInLevel` под ютубом+Xcode build выходит в `warning` хотя бы
  раз за 5 минут. Если нет — значит давления нет в типичной нагрузке,
  и весь mem-substrate переоценён.

Если хотя бы одно условие не выполняется — **остановиться и не идти
в AD-1**, разобраться почему.
