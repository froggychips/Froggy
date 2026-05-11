# Plugin Guide — пишем `LushaAccessor`

🌐 [English](PLUGIN_GUIDE.md) · **Русский**

Froggy относится к *источникам контекста* как к плагинам. Каждый
называется **`LushaAccessor`** и отвечает за один канал данных —
текущий frontmost app, последний OCR-кадр экрана, события календаря,
вкладки браузера, входящие письма — всё, что можно опросить по
требованию. Агент (или любой IPC-клиент) спрашивает демон «дай текущий
снепшот аксессора X» и получает массив строк.

Этот гайд проводит через написание нового аксессора end-to-end.
Целевая аудитория: тот, у кого есть Swift-чекаут Froggy и желание
поднять ещё один сигнал в локальный LLM без правки `main.swift` или
IPC-сервера.

## Когда стоит добавить аксессор

✅ Хорошее применение:
- Одна сущность — один канал (например, *Календарь — следующие 3 события*).
- Дешёвый снимок (< 50 ms обычно). Тяжёлая CPU/IO работа должна
  пред-вычисляться отдельно, а аксессор читает кеш.
- Не требует новых TCC-консентов (или они уже запрошены демоном под
  другую фичу).

❌ Не тот инструмент:
- Мутируете state, шлёте события наружу, запускаете долгие задачи —
  это работа *actor*'а в `VortexCore`, не read-only аксессора.
- Нужно напрямую захватывать экран / микрофон / accessibility-данные.
  Переиспользуйте отредактированные стримы из `LushaBridge`
  (`ContextStore.snapshots()`) вместо параллельной capture-сессии.

## Анатомия аксессора

Протокол лежит в [`Sources/LushaBridge/LushaAccessor.swift`](../Sources/LushaBridge/LushaAccessor.swift):

```swift
public protocol LushaAccessor: Sendable {
    var id: String { get }            // стабильный kebab-case идентификатор в IPC
    var name: String { get }          // человекочитаемая метка
    var experimental: Bool { get }    // default false; см. раздел про experimental
    func snapshot() async -> [String] // текущее значение, одна строка = один факт
}
```

Реализация — ~30 строк. Два встроенных ([`OCRAccessor`](../Sources/LushaBridge/LushaAccessor.swift)
и [`FrontmostAppAccessor`](../Sources/LushaBridge/LushaAccessor.swift)) — хорошие референсы.

## Сквозной пример: `BatteryAccessor`

Выставим состояние зарядки, процент батареи и оценку времени до
разряда. Энтайтлментов не требует — `IOKit` читает power state без TCC.

### 1. Решаем, где живёт

| Зрелость | Лежит в | Маркер |
|---|---|---|
| Стабильный, протестирован, публичный | `Sources/LushaBridge/` | `experimental: false` (default) |
| Прототип, шероховатости допустимы | `Sources/LushaExperimental/` | `experimental: true` |

Battery — стабильное понятие, но если вы прототипируете — начните в
`LushaExperimental`, перенесёте позже. Цена переноса — переименовать
один файл.

### 2. Пишем struct

Создаём `Sources/LushaExperimental/BatteryAccessor.swift`:

```swift
import Foundation
import IOKit.ps
import LushaBridge

public struct BatteryAccessor: LushaAccessor {
    public let id = "battery"
    public let name = "Battery State"
    public let experimental = true

    public init() {}

    public func snapshot() async -> [String] {
        let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        guard let first = sources.first,
              let info = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] else {
            return ["state=unknown"]
        }
        let percent = (info[kIOPSCurrentCapacityKey] as? Int) ?? -1
        let state   = (info[kIOPSPowerSourceStateKey] as? String) ?? "?"
        let ttE     = (info[kIOPSTimeToEmptyKey]     as? Int) ?? -1
        return [
            "percent=\(percent)",
            "state=\(state)",
            "minutesToEmpty=\(ttE)",
        ]
    }
}
```

Что держать в голове:
- **`Sendable`**: все хранимые свойства должны быть `Sendable`. Stateless
  struct'ы проходят бесплатно; замыкания требуют `@Sendable`.
- **`snapshot()` — `async`**: переходите в `MainActor.run { … }` если
  нужен AppKit (паттерн в `FrontmostAppAccessor`).
- **Возврат `[String]`**: один факт — одна строка. Prompt-шаблон агента
  склеит их через `\n`; структурированные wire-форматы (JSON) — отдельная
  забота `IPCResponse`.

### 3. Подключаем в registrar

`main.swift` не знает об индивидуальных аксессорах. Он видит только
объекты `AccessorRegistrar`. У experimental — один общий registrar
[`LushaExperimentalRegistrar`](../Sources/LushaExperimental/LushaExperimental.swift):

```swift
public struct LushaExperimentalRegistrar: AccessorRegistrar {
    public init() {}

    public func register(into registry: AccessorRegistry) async {
        await registry.register(ThermalStateAccessor())
        await registry.register(BatteryAccessor())   // ← добавляем эту строку
    }
}
```

Это единственный файл вне вашего нового аксессора, который вы трогаете.
`main.swift` остаётся без изменений — см. ADR-0011 §EXP-1 для
обоснования паттерна.

Для стабильного (`experimental: false`) аксессора в `LushaBridge`
аналогичный registrar — `LushaBridgeRegistrar`.

### 4. Проверяем через CLI

После `make build`:

```bash
# Список зарегистрированных. Без --experimental — только стабильные.
swift run froggy accessors --experimental
# id=battery       name="Battery State"        experimental=true
# id=thermal       name="Process Thermal State" experimental=true
# id=ocr           name="Screen OCR"            experimental=false
# id=frontmost     name="Frontmost Application" experimental=false

# Тянем снепшот.
swift run froggy snap battery
# percent=84
# state=AC Power
# minutesToEmpty=-1
```

### 5. Используем из LLM

Команда `generate` поддерживает `useContext: true`, который сворачивает
sliding OCR window в prompt. Аксессоры не складываются автоматически —
это разорвало бы prompt каждый вызов. Тяните явно:

```bash
swift run froggy snap battery | swift run froggy gen --prompt "Стоит ли отключить ноут и идти в переговорку?"
```

Или напрямую через IPC:

```bash
echo '{"cmd":"snapshot","accessor":"battery"}' \
  | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
# {"ok":true,"text":"percent=84\nstate=AC Power\nminutesToEmpty=-1","final":true}
```

### 6. Тестируем

Два пути в зависимости от побочных эффектов.

**Чистые / детерминированные** (battery snapshot не детерминирован, но
читает через IOKit — где нет Swift-mock'а): integration-тест в
`Tests/LushaExperimentalTests/`:

```swift
@Test func batteryAccessor_returnsAtLeastStateField() async {
    let snap = await BatteryAccessor().snapshot()
    #expect(snap.contains { $0.hasPrefix("state=") })
}
```

**Stateful** (например, аксессор зависит от `ContextStore` или
внешнего сервиса): инжектируете зависимость через init-параметр и
кормите fake'ом в тесте — как уже сделано в `OCRAccessor(store:)`.

## Experimental vs stable

Флаг `experimental: true` имеет два практических эффекта:

1. **Фильтр видимости.** `froggy accessors` показывает по умолчанию
   только стабильные; передайте `--experimental`, чтобы включить опытные.
2. **Нет SemVer-обещания.** Стабильные аксессоры — часть wire API
   FroggyDaemon: удаление или смена `id` — breaking change
   ([ADR-0003 forward-compat invariants](adr/0003-codable-json-config.md)).
   Experimental можно удалять в patch-релизе.

Когда промоутить experimental → stable:
- API использовался агентом или утилитой ≥ 2 недели без правок.
- Описаны failure modes (что вернёт `snapshot()`, если источник
  недоступен?).
- Либо есть тесты, либо вы решили что источник достаточно mockable.

Для промоушена перенесите файл из `LushaExperimental/` в
`LushaBridge/`, удалите свойство `experimental` (default — `false`), и
перенесите вызов `registry.register(...)` из `LushaExperimentalRegistrar`
в `LushaBridgeRegistrar`.

## Частые ошибки

- **Делать capture внутри `snapshot()`**: не надо. Capture живёт в
  `ScreenStream` / `ContextStore`. Аксессоры читают последний
  закешированный кадр.
- **Возвращать один огромный blob**: разбейте на «один факт — одна
  строка», чтобы агент мог grep'нуть или резюмировать без парсинга.
- **Забыть `@MainActor`**: `NSWorkspace`, `NSRunningApplication` и
  некоторые `IOKit` API требуют main-thread. Оберните `await MainActor.run { … }`
  как в `FrontmostAppAccessor`.
- **Затащить новое TCC-разрешение**: если вашему аксессору нужен
  accessibility, screen recording или microphone consent, которого
  демон сейчас не запрашивает, задокументируйте prompt в
  `packaging/README.md` и обновите `Froggy.entitlements`.

## Смотрите также

- [ADR-0011 — code-first design-second for level-2 features](adr/0011-code-first-design-second-for-level-2.ru.md)
  (обоснование паттерна с registrar'ами).
- [ADR-0015 — frontmost-veto-minimal](adr/0015-frontmost-veto-minimal.ru.md)
  (релевантно: как демон уже знает frontmost-приложение).
- [`LushaBridge/LushaAccessor.swift`](../Sources/LushaBridge/LushaAccessor.swift)
  — протокол + registry + встроенные аксессоры.
- [`LushaExperimental/LushaExperimental.swift`](../Sources/LushaExperimental/LushaExperimental.swift)
  — текущий experimental-registrar и сквозной пример
  (`ThermalStateAccessor`).
