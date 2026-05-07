# ADR 0007 — Pageout-стратегии: machVM / jetsam / scratch

* **Статус:** Accepted (Mem-2)
* **Дата:** 2026-05-06

## Контекст

`SIGSTOP` останавливает процесс, но **не** возвращает RAM ядру: dirty
pages остаются резидентными до тех пор, пока компрессор не решит, что они
кандидат на pageout. На 8 GB Mac эта пассивность — главная причина, почему
«freeze 5 приложений» не освобождает ожидаемые 1–2 GB.

Нужна активная стратегия pageout сразу после `SIGSTOP`.

## Решение

Три стратегии, инкапсулированные в `protocol PageoutImpl` и комбинируемые
через `PageoutChain`:

1. **`machVM`** — `task_for_pid(pid)` → перебор regions через
   `mach_vm_region(VM_REGION_BASIC_INFO_64)` → `mach_vm_behavior_set(addr,
   size, VM_BEHAVIOR_PAGEOUT)` для каждого записываемого не-исполняемого
   региона. Самый прямой и быстрый путь.

   **Цена:** требует `task_for_pid-allow` entitlement, который активируется
   только Apple Developer ID + provisioning profile.

2. **`jetsam`** — `memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES,
   pid, 0, &props, …)` с `priority = JETSAM_PRIORITY_IDLE`. Двигает процесс
   в idle-band, и компрессор берёт его первым, когда давление возникает.

   **Цена:** API в приватном header `<sys/kern_memorystatus.h>` — биндим
   через `@_silgen_name`. Без entitlement'ов, но pageout не моментальный —
   работает в связке с реальным давлением (Mem-1 даёт нам этот сигнал).

3. **`scratch`** — `malloc(N MB) → memset → free`. Провоцирует компрессор
   очистить память кого-то — обычно идёт за самыми «холодными»
   inactive-страницами, а замороженные процессы как раз туда и попадают.

   **Цена:** грубая дубинка, влияет на весь процесс-демон, не таргетная.
   Зато гарантированно выполнится в любом окружении.

`PageoutChain` инициализируется с `preferred: PageoutStrategy` и пробует
стратегии в порядке `preferred → fallbacks`:

| preferred | order |
|---|---|
| `.machVM`  | machVM → jetsam → scratch |
| `.jetsam`  | jetsam → scratch |
| `.scratch` | scratch |

Лог-варн при первом провале каждой стратегии (один раз за сессию), не на
каждый pid.

## Default = `jetsam`

`machVM` в **стандартной third-party поставке не работает на чужих
процессах**. Для активации требуется либо `task_for_pid-allow`
entitlement в provisioning profile, выпущенном Apple специально для
этого приложения (Apple обычно отказывает третьим сторонам — это
право для отладочных утилит самого Apple и платформенных партнёров),
либо отключённый SIP (`csrutil disable`, dev-only). `cs.debugger`
entitlement из hardened runtime — **не эквивалент** `task-for-pid-allow`:
он разрешает attach отладчиком к собственным процессам, но
`task_for_pid()` против чужого pid всё равно даст `KERN_FAILURE`.

`jetsam` работает на любой подписи (включая adhoc) и не требует
entitlement'ов. Реальный pageout случается, когда
`MemoryPressureMonitor` фиксирует `.warning`/`.critical` —
ядро использует jetsam-band как hint при выборе кандидатов.

`scratch` — последний фоллбек: грязная провокация компрессора,
работает где угодно, но влияет на самого демона.

## Последствия

* **+** На Apple Silicon **с одобренным Apple `task-for-pid-allow`
  provisioning profile** или с отключённым SIP получаем синхронный
  pageout — RAM возвращается сразу. Без этого `machVM` упадёт с
  `KERN_FAILURE` и автоматически откатится на `jetsam`.
* **+** На обычной dev-сборке всё работает, просто менее агрессивно.
* **+** Тесты подменяют все три impl через `FakePageoutImpl` — никакого
  настоящего `task_for_pid` в xctest.
* **−** `memorystatus_control` — приватный API. Если xnu внезапно
  поменяет константы — придётся обновить биндинги. Реалистично — раз в
  2-3 года.
* **−** `task_for_pid-allow` сложно получить (Apple ужесточает каждый
  год). Поэтому держим default `jetsam`.

## Альтернативы

* **`madvise(MADV_PAGEOUT)`** — нет в macOS (Linux only).
* **`mlock`/`munlock`** — обратное направление, не помогает.
* **`vm_pressure_notify` + ждать естественного pageout** — слишком долго
  на 8 GB, давление возникает с задержкой и пиковыми спайками.
