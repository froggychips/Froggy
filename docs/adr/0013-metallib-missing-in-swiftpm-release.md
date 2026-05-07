# ADR 0013 — `default.metallib` не собирается через `swift build` (блокер AD-1)

* **Статус:** Accepted (honest-doc — задокументированная проблема, fix отложен)
* **Дата:** 2026-05-07

## Контекст

Validation gate из ADR 0011 требует model-loaded snapshot'а
(`bench/run.sh --save` × 3 сценария). При попытке захватить его —
запуск daemon'а с `--model-path` или `loadModel` через IPC — worker
немедленно умирает с:

```
MLX error: Failed to load the default metallib. library not found
library not found library not found library not found
  at .build/checkouts/mlx-swift/Source/Cmlx/mlx-c/mlx/c/memory.cpp:78
```

Worker не возвращает MLXWorkerEvent.error (ни ready, ни goodbye, ни
error event), просто process exit. Supervisor получает «worker умер
во время операции».

`find .build -name "*.metallib"` — пусто. `swift build -c release`
**не компилирует Metal-shader'ы в `default.metallib`**, и в собранном
binary артефакте этой библиотеки нет нигде.

## Что показал источник mlx-swift

`Source/Cmlx/mlx/mlx/backend/metal/device.cpp::load_default_library_internal`
ищет `default.metallib` в этом порядке:

1. SwiftPM bundle `mlx-swift_Cmlx` через `NSBundle.mainBundle`,
   `allBundles`, `allFrameworks`.
2. Co-located `<binary-dir>/Resources/default.metallib`.
3. Compile-time `default_mtllib_path`.

**Все пять попыток дают `library not found`** — потому что:

* SwiftPM `swift build` не имеет встроенного Metal-shader compiler step
  (это Xcode-only build phase).
* Cmlx target в `mlx-swift/Package.swift` **не объявляет `resources:`**
  с `.metal` файлами, так что SwiftPM не делает с ними ничего.
* Соответственно — `mlx-swift_Cmlx.bundle` создаётся, но `default.metallib`
  внутрь не помещается.

## Почему это не ловилось раньше

Mem-3 разнесла MLX в подпроцесс `FroggyMLXWorker`. Все интеграционные
тесты `MLXSupervisorIntegrationTests` (4 теста: happy / shutdown timeout /
crash mid-generate / rapid loop) используют `FroggyMLXWorkerFake` — Swift
бинарь без `import MLX`, без Metal-зависимостей. Это сделано осознанно
(swift test не должен загружать модели), но **side-effect — реальная
загрузка модели не покрыта end-to-end**.

Validation gate ADR 0011 — первый запуск, который попытался реально
поднять MLX worker в release-сборке. Gate ровно тут и поймал
регрессию, до того как мы пошли в AD-1 строить feature на сломанной
основе.

## Upstream state (проверено 2026-05-07)

* **mlx-swift в Package.resolved: 0.31.3** — это последний релиз. Bump
  не поможет, fix не вышел.
* **[mlx-swift#349](https://github.com/ml-explore/mlx-swift/issues/349)** —
  открыт с февраля 2026, ровно наша симптоматика (Tuist-вариант). Maintainer
  ответил буквально: *«swiftpm has no mechanism to build the metal shaders
  or the metallic. ... using xcodebuild (or CMake) is a workaround»*.
* **[mlx-swift#345](https://github.com/ml-explore/mlx-swift/issues/345)** —
  открыт январь 2026: «Sanity check - build/packaging instructions with
  bundle Metal libraries». Тоже без решения.
* **[mlx-swift#313](https://github.com/ml-explore/mlx-swift/pull/313)
  «MetalCompilerPlugin support»** — community-PR от gin66, висит с
  декабря 2025, **CONFLICTING + REVIEW_REQUIRED**, ни одного review
  за 5 месяцев. Зависит от companion-PR в `ml-explore/mlx` (C++ репо).
  Не путь.
* В комментариях #349 — community workarounds: SwiftPM `BuildToolPlugin`
  с локальной shell-скриптом, копирующим metallib. Это и есть наш Path 1.

**Вывод:** официального upstream-fix'а в обозримом будущем не будет.
Решать локально.

## Решение

**Этот ADR не предлагает фикс — он фиксирует known-blocker.** Fix
требует выбора между несколькими путями, каждый из которых занимает
часы–дни и не должен делаться «попутно» в bench-сессии.

Возможные пути (в порядке возрастания инвазивности):

1. **Pre-build script + SwiftPM resource declaration.** Скомпилировать
   `default.metallib` через `xcrun -sdk macosx metal -c …` + `xcrun -sdk
   macosx metallib …` в pre-build hook, объявить как `.process` resource
   в Cmlx target'е. Минус: меняем upstream Package.swift (через patch
   в нашем репо или форк), плюс build-зависимость от Xcode CLI tools.

2. **Параллельный xcodebuild target.** Создать `xcodeproj` для FroggyMLXWorker,
   собирать его через `xcodebuild` (Xcode компилирует metallib
   автоматически), плюс post-build copy в `.build/release/`. Минус:
   две build-системы для одного репо, CI становится сложнее.

3. **Заменить mlx-swift на binary XCFramework.** Apple раздаёт
   pre-built MLX через `mlx-swift/xcframework` (если такой есть). Минус:
   меньше гибкости, не уверен что есть в наличии.

4. **Заявить «MLX worker работает только в Xcode-built app bundle».**
   Принять, что Froggy — это Mac app, не CLI; собирать через `xcodebuild`
   в полноценный `.app`. Минус: меняет deployment story, и тесты, и
   CI.

Решение откладывается до пост-сессии — нужно посмотреть upstream
issue/PR'ы в `mlx-swift` и выбрать наименее инвазивный путь.

## Что делать ДО фикса

1. **AD-1 / FCP-1 / EXP-1 — заблокированы.** ADR 0011 явно требует
   model-loaded snapshot, и без него gate не PASS. Не бойти в Уровень 1.5.

2. **Дозахват `under-pressure` snapshot'а — уже есть** (см. `bench/baseline.json`).
   Idle snapshot v2 — есть. Нет только model-loaded.

3. **Не заводить ADR 0014+ под Уровень 2** — это и так блокировано
   ADR 0011, а теперь ещё и ADR 0013. Двойной gate.

4. **Тесты — оставить как есть.** Не заменять `FroggyMLXWorkerFake` на
   реальный worker, пока metallib не починен — иначе `swift test`
   тоже сломается.

## Последствия

* **+** Gate ADR 0011 доказал ценность повторно: без него мы бы пошли
  в AD-1 и поймали бы это в середине frontmost-veto работы. Сейчас
  поймано в чистом контексте, можно решать отдельно.
* **+** Изоляция Mem-3 (worker как отдельный процесс) ИЗОЛИРУЕТ эту
  проблему — daemon работает корректно даже когда worker не может
  загрузиться (worker возвращает ошибку → supervisor возвращает её
  пользователю → daemon не падает).
* **−** AD-1 на паузе на ~1 сессию (фикс metallib).
* **−** Honest-doc'ов растёт: 0009 (design follows code), 0011 (gate),
  0012 (signing reality), 0013 (build reality). Не баг, фича: каждый
  фиксирует расхождение между «что мы думали» и «что есть».

## Ссылки

* ADR 0011 — gate, теперь явно блокирует и эта проблема.
* `bench/cycles_test.sh` — orchestrator скрипт для 5-цикловой проверки
  gate-criterion после фикса.
* `Source/Cmlx/mlx/mlx/backend/metal/device.cpp` (mlx-swift checkout) —
  где идёт поиск metallib и формируется ошибка.
