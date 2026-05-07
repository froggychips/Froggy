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

`baseline.json` — массив. Schema v2 (v1 совместим: `daemon_rss_kb` =
median из distribution). Каждый snapshot:

| поле | что |
|---|---|
| `scenario` | `idle` / `model-loaded` / `under-pressure` |
| `daemon_rss_kb` | **median** RSS демона из 10 сэмплов (см. ниже про sawtooth). |
| `daemon_rss_kb_distribution` | `{min, median, max, mean, samples[10]}`. Под pressure'ом sawtooth 50-150 MB — single-sample обманчив, всегда смотреть median+max. |
| `worker_rss_kb` / `worker_rss_kb_distribution` | то же для worker'а. Для 4-bit 4B ожидается median ~3 GB. |
| `ttft_ms` | time-to-first-token. Только при `model-loaded`. |
| `vm_stat_raw` | сырой `vm_stat`. Смотреть `compressed`, `pages free`, `pages active`. |
| `froggy_pressure` | сырой ответ `pressure`. Смотреть `pageoutCounters` — реально ли pageout что-то делает (любая стратегия). |

## Sawtooth — почему distribution, а не single-sample

Под critical-pressure RSS daemon'а живёт sawtooth'ом 50-150 MB на
интервалах ~секунд. Причина: Vision/SCStream держат IOSurface буферы
в clean-mapped памяти, и kernel под давлением периодически evict'ит
эти страницы; на следующем OCR-цикле они re-fault'ятся. Это **не leak** —
`heap` показывает константные `CRImageReaderOutput` объекты после
10+ минут.

Single-sample `ps -o rss=` ловит произвольную точку этого sawtooth'a —
30 MB или 180 MB с примерно равной вероятностью. **`median` из 10 сэмплов
с интервалом 1s — стабильная и сравнимая метрика.**

## Что считать «разумным»

В рамках THESIS criterion #2 — substrate должен дать выигрыш, который
без него не получишь. Конкретные ожидания (см. ADR 0011 § «Validation
gate»):

* `daemon_rss_kb_distribution.median` без модели **≤ 130 MB**, `min ≥ 30 MB`.
  Это floor от Vision+SCStream+AppKit (transitive через ScreenCaptureKit) —
  фреймворковая база macOS, неустранима без отказа от OCR-цикла.
  Если median > 200 MB или max > 400 MB — это уже регрессия, разбираться.
* После `unloadModel` `worker_rss_kb_distribution` → all null **и**
  daemon distribution возвращается к idle ± 50 MB по median.
* В `under-pressure` сценарии `pageoutCounters.<any>.succeeded ≥ 1` —
  хотя бы одна стратегия (jetsam / scratch / machVM) сработала. Jetsam
  без `task_for_pid_allow` ожидаемо EPERM'ит (см. ADR 0007/0012),
  scratch-fallback должен подхватить.
* `secondsInLevel` под ютубом+Xcode build выходит в `warning` хотя бы
  раз за 5 минут. Если нет — значит давления нет в типичной нагрузке,
  и весь mem-substrate переоценён.

Если хотя бы одно условие не выполняется — **остановиться и не идти
в AD-1**, разобраться почему.
