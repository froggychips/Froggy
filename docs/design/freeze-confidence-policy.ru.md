# Design: Политика Freeze Confidence

| Поле | Значение |
|---|---|
| Статус | Draft |
| Фаза | Уровень 1.5 — Trust Governance |
| Зависит от | [`activity-detection.md`](activity-detection.md), Mem-1 (`MemoryPressureMonitor`) |
| Связано с | [`THESIS.md`](../THESIS.md), предстоящий [`explainability-menubar.md`](explainability-menubar.md) |

## Зачем это нужно

[`activity-detection.md`](activity-detection.md) определяет, как Froggy
*знает*, используется ли процесс активно. Этот документ определяет, как Froggy
*действует* на основе этого знания — логику принятия решений между
`MemoryPressureMonitor` (который говорит «нужно освободить память») и
`Vortex.freeze` (который непосредственно выполняет заморозку).

Чистой проверки порога confidence недостаточно. Решение требует четырёх
дополнительных входных данных:

1. **Cooldown'ы** — одно и то же приложение не должно замораживаться дважды
   за 30 секунд. Это не управление памятью, это on/off-пульс чат-приложения.
2. **Бюджеты заморозки** — ни одно приложение не замораживается более чем
   на X минут в час, независимо от pressure. Иначе фоновое WebSocket-приложение
   умрёт под постоянным давлением.
3. **Watchdog по максимальной длительности** — даже при постоянном pressure ни
   одна заморозка не длится дольше Y минут без принудительной разморозки и
   переоценки.
4. **Per-app переопределения** — пользователь имеет последнее слово: явный
   allow-list, deny-list, кастомные пороги.

Без этого решения о заморозке «корректны» в моменте, но в совокупности
производят враждебный UX: приложения осциллируют, WebSocket-соединения рвутся,
уведомления теряются. **Policy** — это то, что превращает моментально-корректные
события заморозки в приемлемое для пользователя поведение со временем.

## Цели

1. Принимать confidence-score активности и уровень pressure, производить решение
   **freeze / skip / force-thaw** со структурированным трейсом.
2. Применять cooldown'ы и бюджеты *атомарно* — без гонки, при которой кандидат
   может проскользнуть мимо проверки бюджета.
3. Сохранять достаточно состояния для выживания перезапуска daemon'а без потери
   доверия («Slack только что принудительно разморозило, потому что daemon
   перезапустился и забыл, что достиг бюджета»).
4. Экспонировать весь контекст решения в
   [`explainability-menubar.md`](explainability-menubar.md) как структурированный
   трейс — никогда не логировать произвольные строки как основную запись.
5. Быть наблюдаемым и настраиваемым без перекомпиляции. Пороги, бюджеты и
   переопределения — всё живёт в `FroggyConfig`.

## Вне scope

- **Не** обучающаяся система. То же, что обнаружение активности — rules-based,
  объяснимо, без ML.
- **Не** место где вычисляются отдельные сигналы (это — обнаружение активности).
- **Не** место где объяснения рендерятся для людей (это — документ о menubar).
- **Не** per-PID throttle. Заморозки/cooldown'ы/бюджеты отслеживаются по
  **bundle id**, потому что PID меняется при перезапуске, а восприятие пользователя —
  «Slack снова заморозило», не «PID 2147 снова заморозило».

## Место в стеке

```
┌──────────────────────────────────────────────────────────────────┐
│ MemoryPressureMonitor → AsyncStream<MemoryPressureLevel>         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ FreezePolicyEngine.evaluate(level, candidate)  ◀── этот doc      │
│                                                                  │
│   1. lookup overrides for candidate.bundleId                     │
│   2. ask ActivityDetector.confidence(forPid: candidate.pid)      │
│   3. check cooldown (state[bundleId].lastFreezeEnded)            │
│   4. check budget (state[bundleId].cumulativeFreezeThisHour)     │
│   5. compare confidence vs tier-threshold                        │
│   6. emit Decision { freeze | skip | thaw, reason, trace }       │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ VortexCoordinator → Vortex.freeze / Vortex.thaw                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ FreezePolicyEngine.recordOutcome(decision, result)               │
│   updates state[bundleId]: lastFreezeStarted, .ended,            │
│                            cumulative, currentlyFrozenSince      │
└──────────────────────────────────────────────────────────────────┘
```

`FreezePolicyEngine` — новый актор в `VortexCore`. Он владеет мутабельной
state-картой `[bundleId: AppFreezeState]` и экспонирует evaluation + recording.
Coordinator теперь тонкий — реагирует на pressure, запрашивает policy engine
per-кандидату, применяет то, что engine вернул.

## Модель состояния

```swift
struct AppFreezeState: Sendable {
    let bundleId: String
    var lastFreezeStarted: Date?
    var lastFreezeEnded: Date?
    var currentlyFrozenSince: Date?     // nil = не заморожено сейчас
    var cumulativeFreezeWindow: SlidingWindow<Duration> // последние 60 мин
    var consecutiveFreezeCount: Int      // сбрасывается в 0 после `restPeriod`
    var schemaVersion: Int               // для SQLite-миграций
}

enum FreezeDecision: Sendable {
    case freeze(reason: FreezeReason, trace: DecisionTrace)
    case skip(reason: SkipReason, trace: DecisionTrace)
    case thaw(reason: ThawReason, trace: DecisionTrace)
    case noop  // кандидат вообще не подходит
}
```

`cumulativeFreezeWindow` — скользящее 60-минутное окно, а не часовой бакет.
Часовые бакеты создают cliff-эффекты («только что был под бюджетом в 10:59,
теперь в 11:00 у меня свежий бюджет»), которые выглядят как баги. Скользящее
окно стоит немного больше памяти (одна запись per событие заморозки за последний
час), но честно.

Состояние сохраняется в SQLite-файл рядом с `freeze_stats.sqlite` из Mem-5
(или в итоге объединяется в одну схему — TBD). Поведение при перезапуске:

- При старте: загружаем все строки `AppFreezeState`. Всё с
  `currentlyFrozenSince != nil` — остатки краша → принудительная разморозка
  через существующий механизм восстановления `frozen.pids`, отметить
  `lastFreezeEnded = now`.
- Cooldown'ы и кумулятивные окна переживают перезапуск корректно.

## Поток принятия решений

```swift
func evaluate(
    level: MemoryPressureLevel,
    candidate: FreezeCandidate
) -> FreezeDecision {
    let trace = DecisionTrace(timestamp: clock.now, pid: candidate.pid)

    // 1. Eligibility — exclusion list всегда побеждает
    if config.freezeExclusion.contains(candidate.bundleId) {
        return .noop
    }

    // 2. Lookup порога per-tier
    let threshold = config.thresholdFor(level: level, tier: candidate.tier)

    // 3. Проверка переопределения до запроса активности
    if let override = config.confidenceOverrideFor(candidate.bundleId) {
        // Зафиксировано на высокий confidence → никогда не замораживать в этой policy
        if override >= threshold {
            return .skip(reason: .userOverride(override), trace: trace)
        }
        // Зафиксировано на 0 → полностью обойти обнаружение активности
        if override == 0.0 {
            // Всё ещё подчиняется cooldown/budget
            return checkCooldownAndBudget(...)
        }
    }

    // 4. Проверка cooldown
    if let lastEnded = state[bundleId]?.lastFreezeEnded {
        let elapsed = clock.now.timeIntervalSince(lastEnded)
        if elapsed < cooldownFor(candidate.bundleId) {
            return .skip(reason: .cooldown(remaining: ...), trace: trace)
        }
    }

    // 5. Проверка бюджета
    let usedThisHour = state[bundleId]?.cumulativeFreezeWindow.total ?? 0
    let budget = budgetFor(candidate.bundleId)
    if usedThisHour >= budget {
        return .skip(reason: .budgetExhausted(...), trace: trace)
    }

    // 6. Confidence активности
    let confidence = await activityDetector.confidence(forPid: candidate.pid)

    if confidence.score >= threshold {
        return .skip(reason: .activeUser(score: ...), trace: trace.merging(confidence))
    }

    return .freeze(reason: .pressurePolicy(...), trace: trace.merging(confidence))
}
```

Трейс накапливает контекст по мере продвижения функции. `.skip`, возвращённый
на шаге 4, содержит только контекст cooldown; возвращённый на шаге 6 —
полный трейс сигналов активности. Это входные данные,
которые потребляет [`explainability-menubar.md`](explainability-menubar.md).

## Триггеры авто-разморозки

Замороженное приложение размораживается ровно одним из следующих:

| Триггер | Когда | Поведение |
|---|---|---|
| Pressure нормализовался | `MemoryPressureMonitor` сообщает `.normal` на протяжении `gradualThawDelaySeconds` | Tier-2 немедленно, tier-1 после задержки (существующая логика Mem-1) |
| Бюджет исчерпан в процессе заморозки | `cumulativeFreezeWindow` превышает `budget` во время заморозки | Принудительная разморозка, запрет на повторную заморозку на `restPeriod` (по умолчанию 10 мин) |
| Превышена максимальная длительность | Достигнуто `currentlyFrozenSince + maxFreezeDuration` | Принудительная разморозка + лог предупреждения. Повторно eligible после `cooldown`. |
| Обнаружена внешняя активность | Переход на frozen-приложение на передний план, открытие аудио-сессии | Мгновенная разморозка + критический лог предупреждения («мы не должны были быть заморожены») |
| Явная разморозка пользователем | IPC `thaw <pid>` или `thawAll` | Мгновенная разморозка, обход всего состояния |
| Приложение завершилось | Процесс исчез | Очистить состояние, разморозка не нужна |

Случай «обнаружена внешняя активность» — **trust-canary**: если он
когда-либо срабатывает, наше решение о заморозке было ошибочным. В production —
действие: разморозка + предупреждение. В тестах это дополнительно должно
отказывать громко (assertion в debug-сборках) — это указывает на баг в
confidence-скоринге в вышестоящем обнаружении активности.

## Значения по умолчанию

```json
{
  "freezeBudget": {
    "default": "PT15M",
    "perBundle": {
      "com.tinyspeck.slackmacgap": "PT5M",
      "notion.id": "PT10M"
    }
  },
  "freezeCooldown": {
    "default": "PT60S",
    "perBundle": {}
  },
  "maxFreezeDuration": {
    "default": "PT15M",
    "perBundle": {}
  },
  "freezeRestPeriod": {
    "default": "PT10M"
  },
  "activityConfidenceOverride": {
    "com.1password.1password8": 1.0,
    "com.tinyspeck.slackmacgap-during-call": 1.0
  },
  "freezeExclusion": [
    "com.apple.WindowServer",
    "com.apple.dock"
  ]
}
```

(`PT15M` = длительность ISO-8601. Нативный Swift `Duration` codable
не является ISO; будет использован небольшой кастомный decoder.)

Чтение дефолтов:

- **Бюджет 15 мин в час, cooldown 1 мин** — при постоянном pressure приложение
  получает ~15 мин заморозки + ~45 мин активности в час. Достаточно долго,
  чтобы освободить значимый объём RAM; достаточно коротко, чтобы WebSocket
  reconnect'ы не теряли состояние.
- **Максимум 15 мин на одну заморозку** — даже если pressure остаётся
  critical, ни одна заморозка не блокирует приложение более 15 мин до
  переоценки. Приложение получает шанс обработать то, чем занималось.
- **Период отдыха 10 мин после исчерпания бюджета** — как только приложение
  достигает часового бюджета, Froggy не трогает его 10 мин. Это бюджет
  доверия — Froggy буквально не будет пытаться снова.
- **`restPeriod < cooldown < maxDuration < budget`** — инвариант,
  поддерживаемый валидацией конфига при старте.

### Редактирование исключений и переопределений во время работы

`freezeExclusion` и `activityConfidenceOverride` — пользовательские элементы
управления доверием. Пользователь может изменить их двумя равнозначными способами:

1. **Отредактировать `~/Library/Application Support/Froggy/config.json` и
   перезапустить daemon.** Стабильно, scriptable, источник истины.
2. **Нажать `[never freeze]` на per-app строке в menubar** (см.
   [`explainability-menubar.md`](explainability-menubar.md) L3). Menubar
   отправляет `addExclusion <bundleId>` через IPC; daemon обновляет конфиг
   в памяти, сохраняет в `config.json` и инициирует немедленную разморозку
   при необходимости. Перезапуск не требуется.

Оба пути производят одинаковое итоговое состояние. IPC-путь существует потому,
что просить пользователя в момент фрустрации («Slack только что заморозился
во время звонка») редактировать JSON и перезапускать daemon — нереалистично.
Встроенное исключение — механизм восстановления доверия после плохой заморозки.

Замечание по реализации: шаг записи на диск использует атомарную запись
(запись во временный файл + rename), чтобы избежать повреждения `config.json`
при краше в процессе записи.

## API

```swift
public actor FreezePolicyEngine {
    public init(
        config: FroggyConfig,
        activityDetector: any ActivityDetecting,
        clock: any Clock<Duration>,
        store: any FreezeStateStore
    )

    public func evaluate(
        level: MemoryPressureLevel,
        candidate: FreezeCandidate
    ) async -> FreezeDecision

    public func recordOutcome(
        _ decision: FreezeDecision,
        result: FreezeOutcome
    ) async

    public func liveDecisions() -> AsyncStream<FreezeDecision>
}

public protocol FreezeStateStore: Sendable {
    func load() async throws -> [String: AppFreezeState]
    func save(_ state: AppFreezeState) async throws
    func clear(bundleId: String) async throws
}
```

Стрим `liveDecisions()` — то, на что подписывается menubar. Каждое решение
(включая `.noop` и `.skip`) публикуется — они полезны пользователю, чтобы
видеть «Froggy рассмотрел Slack, но пропустил из-за cooldown».

## Режимы отказа

| Отказ | Обнаружение | Поведение |
|---|---|---|
| `ActivityDetector.confidence` таймаутит (> 100 мс) | Task timeout | `.skip(reason: .activitySignalUnavailable)` — fail-safe к отсутствию заморозки |
| Запись в SQLite не удалась | Throws при `save()` | Решение всё равно применяется в памяти; лог предупреждения; повтор при следующем решении |
| Загрузка SQLite при старте не удалась | Throws при `load()` | Стартуем с пустым состоянием; критический лог; cooldown'ы/бюджеты сброшены (одноразовая деградация) |
| Скачок времени (системное время прыгнуло назад) | Скользящее окно обнаруживает отрицательный интервал | Отбрасываем записи до прыжка из окна, не применяем прыжок как «бесплатный бюджет» |
| Bundle id меняется для того же приложения (ребрендинг) | Новая запись, старая остаётся | Допустимо — старое состояние естественно устаревает из скользящего окна |

Два принципа, подкрепляемых везде: **fail closed (не замораживать при
неопределённости), сохранять всё возможное, никогда не терять доверие
пользователя из-за ошибки хранилища**.

## Поэтапная реализация

| ID | Scope | Приёмка |
|---|---|---|
| FCP-1 | Skeleton `FreezePolicyEngine` + threshold-based решение (потребляет confidence активности, без бюджетов/cooldown'ов) | Coordinator делегирует все решения о заморозке engine'у; трейс заполняется; существующая tier policy Mem-1 воспроизводится через пороги |
| FCP-2 | Cooldown'ы | Повторная заморозка того же приложения в пределах cooldown возвращает `.skip(reason: .cooldown)` |
| FCP-3 | Скользящий бюджет | Приложение, достигшее бюджета в процессе заморозки, принудительно размораживается + получает период отдыха |
| FCP-4 | Watchdog максимальной длительности | Замороженное приложение принудительно размораживается при maxDuration независимо от pressure |
| FCP-5 | Persistence (SQLite) + восстановление после краша | Перезапуск daemon'а сохраняет cooldown'ы и бюджеты; осиротевшие заморозки от краша восстанавливаются |
| FCP-6 | IPC-стрим `liveDecisions()` | Menubar может подписаться; структурированный трейс течёт |
| FCP-7 | Per-app переопределения конфига (исключение, фиксация порога, кастомный бюджет/cooldown) | Все переопределения в `FroggyConfig` работают с валидацией конфига при старте |

FCP-1 и FCP-2 — минимально жизнеспособное trust governance. FCP-1 делает
заморозки *отзывчивыми* к активности пользователя; FCP-2 делает их
*ненавязчивыми*. Всё остальное — уточнения.

## Тесты

Юнит-тесты:

- **Пороговый gate**: при каждом `MemoryPressureLevel × tier` заморозка корректно
  регулируется инжектированными confidence-значениями вокруг порога (чуть ниже,
  ровно на, чуть выше).
- **Cooldown**: воспроизводим последовательность с инжектированными clock'ами —
  `freeze; thaw; немедленная попытка заморозки → skip; продвигаем clock за cooldown;
  попытка заморозки → freeze`.
- **Бюджет**: 30 маленьких заморозок, в сумме достигающих бюджета → следующая
  попытка принудительно skip; продвигаем clock на 1 ч → бюджет обновлён.
- **Максимальная длительность**: долгая заморозка при постоянном pressure →
  принудительная разморозка при maxDuration; последующая повторная заморозка
  соблюдает cooldown.
- **Приоритет переопределений**: exclusion > confidence override >
  cooldown/budget > activity threshold.

Интеграционные тесты:

- Реальный `ActivityDetector` со stub signal sources, реальный clock; выполняем
  end-to-end поток решений на реалистичном паттерне pressure.
- Восстановление после краша: записываем состояние в SQLite, убиваем engine
  в процессе заморозки, перезапускаем, проверяем соответствие восстановленного
  состояния.

Snapshot-тесты:

- Трейсы решений для канонических сценариев (cooldown skip, budget skip,
  active-user skip, freeze под pressure) — зафиксированы в репо как ожидаемый
  JSON, регенерируются при намеренном изменении.

Планка приёмки: **каждая заморозка в E2E-тестах имеет непустой трейс**,
и **ни один тест не проходит, нарушающий принцип fail-closed** (например,
таймаутный запрос активности, производящий `.freeze` — это провал теста).

## Открытые вопросы

1. **Что делать при катастрофическом pressure, когда все кандидаты выше порога?**
   Крайний случай: каждый кандидат имеет высокий confidence, pressure остаётся
   critical, надвигается OOM. Варианты:
   - Переопределить порог (снизить его динамически, пока *какой-то* кандидат
     не станет eligible).
   - Сначала вызвать `unloadModel` на MLX worker'е, откатываясь к заморозке
     только после того, как сама модель выгружена.
   - Показать уведомление «Froggy не может освободить RAM без нарушения
     активной работы — закройте что-нибудь или уменьшите размер модели».
   Нужно выбрать один вариант. Склоняемся к варианту 2 (пожертвовать моделью
   прежде чем активными приложениями пользователя), но это решение уровня тезиса
   и заслуживает отдельного ADR до FCP-3.
2. **Cooldown vs бюджет — одна шкала или независимые?** Сейчас независимые.
   Возможно, стоит сделать бюджет функцией от cooldown (более длинный cooldown =
   больше бюджета), чтобы сократить поверхность конфига. Откладывается до
   реальных данных использования.
3. **`liveDecisions()` — protocol-typed AsyncStream или конкретный?** Конкретный
   проще. Protocol-typed позволяет menubar подставлять фейки для SwiftUI preview.
   Склоняемся к конкретному, если только preview не станет болезненным.
4. **Пороги per-tier vs per-bundle.** Сейчас per-tier. Некоторым bundle'ам
   законно нужны per-bundle пороги (например, видеоредактор, который иногда
   уходит в фон в середине рендера). Откладывается.

## Связь с THESIS

Согласно [`THESIS.md`](../THESIS.md), уровень trust governance — это
**обязательное** и первое пользовательское возможности Уровня 1.5. Freeze
confidence policy — несущий компонент принятия решений этого слоя:

- Это **качественно** — без него заморозка бинарна (всегда замораживать под
  pressure / никогда не замораживать). С ним заморозка становится контекстной,
  учитывающей время и бюджет.
- Это **фильтр**, отклоняющий критику «уберите заморозку совсем», одновременно
  уважая «не ломайте рабочие процессы пользователя». Оба могут быть истиной
  одновременно, и policy — механизм, делающий их таковыми.
- Трейс, который он производит — **входные данные** для слоя объяснимости,
  который пользователь реально видит. Без трейсов policy menubar не имеет
  ничего честного для показа.

Комбинация *(обнаружение активности → policy → объяснимость)* — это то, что
THESIS называет «доверительный слой сам является возможностью». Этот документ —
средний член этой тройки.
