# ADR 0012 — Signing constraints: что реально работает на разных подписях

* **Статус:** Accepted (honest-doc после первого реального bench'а)
* **Дата:** 2026-05-07

## Контекст

ADR 0007 описывал три pageout-стратегии (`machVM` / `jetsam` / `scratch`)
и причины, почему default = `jetsam`. Это было основано на reading'е xnu
исходников и Apple-документации. После первого реального прогона
`bench/run.sh --save` под critical pressure'ом картина оказалась
немного жёстче, чем 0007 предполагал. Этот ADR — honest-doc того, что
**фактически работает** на разных уровнях подписи.

ADR 0011 (validation gate) изначально требовал `pageoutCounters.jetsamSucceeded ≥ 1`.
Этот критерий пришлось ослабить до «любая стратегия succeeded ≥ 1»,
ровно потому что bench показал реальное состояние на personal dev signing.

## Наблюдение

Первый бенч-snapshot (`bench/baseline.json[0]`, captured 2026-05-07,
build на personal Apple Developer signing без custom provisioning, SIP
включён):

```json
"pageoutCounters": {
  "machVMAttempted": 0,
  "jetsamAttempted": 1, "jetsamFailed": 1, "jetsamSucceeded": 0,
  "scratchAttempted": 1, "scratchSucceeded": 1, "scratchFailed": 0
}
```

`machVMAttempted = 0` — ожидаемо, default `jetsam` не пытается machVM.
Если бы пытался, было бы 1/0/1 (Failed) — `task_for_pid` без entitlement'а
сразу даёт `KERN_FAILURE`.

`jetsamAttempted = 1, jetsamFailed = 1` — **сюрприз относительно ADR 0007.**
0007 предполагал, что `memorystatus_control` без entitlement'ов отрабатывает
в любой подписи. На практике ядро в нашей конфигурации возвращает
`EPERM` для попытки выставить `JETSAM_PRIORITY_IDLE` чужому процессу
без `task_for_pid-allow` или подходящих платформенных привилегий.

`scratchSucceeded = 1` — провокация компрессора через `malloc/memset/free`
работает безусловно, потому что не обращается к чужим pid'ам — просто
заставляет ядро сжать чьи-то холодные страницы. Это и спасло substrate
в первом бенче.

## Решение

Зафиксировать **фактическую матрицу работоспособности** по уровню подписи.
Это не означает изменения кода — `PageoutChain` уже корректно откатывается
при провале. Это означает:

1. **Не блокировать substrate-разработку на получении `task-for-pid-allow`.**
   Apple предоставляет этот entitlement редко (фактический отказ третьим
   сторонам в большинстве случаев), процедура занимает недели-месяцы.
   Substrate уже **функционально работает** через scratch fallback на
   personal dev signing — этого достаточно для capability-фаз.

2. **`pageoutCounters.<any>.succeeded ≥ 1` — корректный критерий
   готовности**, а не jetsam-specific. ADR 0011 § «Validation gate»
   обновлён соответственно.

3. **Документировать матрицу подписей** для будущих читателей кода и для
   принятия решений «нужно ли подавать на `task-for-pid-allow`».

## Матрица работоспособности pageout-стратегий

| Стратегия | personal dev signing (текущая сборка) | Apple Developer ID + `task-for-pid-allow` provisioning | SIP отключён (`csrutil disable`) |
|---|---|---|---|
| `machVM` | ❌ `task_for_pid` → `KERN_FAILURE` | ✅ работает на чужих pid'ах | ✅ работает |
| `jetsam` (`memorystatus_control`) | ⚠ `EPERM` в нашей конфигурации (наблюдалось 2026-05-07) | ✅ ожидается, не подтверждено бенчем | ✅ ожидается |
| `scratch` (компрессор-провокация) | ✅ безусловно | ✅ | ✅ |

«Ожидается, не подтверждено бенчем» означает: API-доступ есть, но без
реальной сборки с этими условиями не проверено. До первой такой сборки
относиться как к гипотезе.

## Последствия

* **+** Substrate работает сегодня, на default-подписи разработчика, без
  внешних зависимостей. Validation gate (ADR 0011) выполнимо локально.
* **+** Apple-procedure (`task-for-pid-allow` request) явно не на
  критическом пути. Если соберёмся подаваться — это выигрыш в скорости
  pageout'а (machVM синхронный), а не unblock substrate'а.
* **−** Default-конфигурация substrate'a менее эффективна: scratch
  «бьёт по всему демону» (заставляет компрессор сжать что попало),
  jetsam был бы таргетнее. Эффект: иногда мы выжимаем не только
  замороженные приложения, но и собственные холодные страницы. На
  8 GB Mac под critical pressure'ом — приемлемая цена.
* **−** Если xnu в будущем macOS уберёт scratch-эффект (например, оптимизирует
  компрессор так, что `malloc/memset/free` больше не двигает чужие
  страницы) — substrate потеряет последнюю стратегию на personal dev
  signing. Mitigation: следить за `pageoutCounters.scratchSucceeded`
  в bench'ах при апгрейдах macOS.

## Что НЕ делать

* **Не подавать на `task-for-pid-allow` ради substrate'а.** Если когда-то
  понадобится для другой фичи (например, реального debug-таргета) —
  поставить в `TODO.md`, не блокировать капабилити-работу.
* **Не отключать SIP в инструкциях для пользователей.** Для substrate'а
  это не нужно — scratch работает без SIP-off. Просить кого-то отключить
  SIP «чтобы Froggy лучше работал» — нарушение здравого смысла.
* **Не ужесточать критерий `pageoutCounters` обратно к jetsam-specific.**
  Это были бы уход обратно к мнению-вместо-факта; bench показал реальность.

## Ссылки

* ADR 0007 — описание трёх стратегий и почему default jetsam (теоретическая
  база; этот ADR корректирует practical-часть).
* ADR 0011 — validation gate перед AD-1; § «не идти в AD-1» обновлён под
  any-strategy критерий.
* `bench/baseline.json[0]` — первый snapshot, на котором это поведение
  наблюдалось.
