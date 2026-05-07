# ADR 0008 — MLX-инференс в отдельном процессе

* **Статус:** Accepted (Mem-3)
* **Дата:** 2026-05-06

## Контекст

`MLX.Memory.clearCache()` после `unloadModel` **не возвращает** peak unified
memory ядру: значимая часть страниц остаётся в адресном пространстве
демона до его собственного завершения. На 8 GB Mac это означает, что
один цикл `loadModel(7B-4bit) → unloadModel` оставляет демон с +2 GB
RSS, который не исчезает.

Единственный надёжный способ вернуть память ядру — убить процесс,
который её аллоцировал.

## Решение

1. Новый executable `FroggyMLXWorker` — содержит ровно одну `ModelContainer`
   и логику генерации поверх `mlx-swift-lm`. Демон запускает его как
   дочерний процесс при `loadModel`.
2. IPC между демоном и worker'ом — Unix pipe (`Process.standardInput` /
   `standardOutput`) + JSON-line. Каждая строка stdin — `MLXWorkerCommand`,
   каждая stdout — `MLXWorkerEvent`. Тот же стиль, что у основного IPC,
   чтобы не плодить форматов. Не XPC: XPC требует launchd-регистрации
   service-name'a и подписи, что усложняет dev-цикл.
3. `MLXActor` переименован в `MLXSupervisor`. Он держит `Process` + pipe,
   readabilityHandler парсит stdout, диспатчит события по `requestId` →
   pending continuation'ам. На `unloadModel` шлёт `shutdown`, ждёт
   `goodbye` до 3 секунд, потом SIGKILL. После выхода ребёнка peak
   memory возвращается ядру.
4. `MLXLLM`/`MLXLMCommon`/`MLXHuggingFace`/`Tokenizers` — теперь зависимости
   только `FroggyMLXWorker`. `VortexCore` импортирует только
   `MLXWorkerProtocol` (Codable wire-формат). Это значит: даже если
   модель никогда не загружалась, демон не тянет в адресное пространство
   MLX runtime.
5. На крах worker'а во время генерации текущие continuation'ы получают
   `MLXSupervisorError.workerCrashed`, `isLoaded()` → false, status в IPC
   отражает разгрузку. Следующий `loadModel` поднимет нового worker'а.
6. `FrozenPidsStore.Entry` получил поле `category: String?`. Worker
   спавнится с `category = "worker"`. На startup demon'a `recover()`
   видит worker-сирот и **убивает их `SIGKILL`** (вместо SIGCONT), потому
   что после краха демона worker не нужен — модель в его памяти
   некому использовать.

## Последствия

* **+** Гарантированный возврат RAM на `unloadModel`. Главная цель Mem-3
  достигнута.
* **+** MLX runtime больше не «висит» в демоне. Демон без модели весит
  ~50 MB вместо ~500 MB.
* **+** Краш worker'а не валит весь демон. OCR, IPC, Vortex продолжают
  работать; пользователь может перезагрузить модель.
* **+** Тестируемость: тесты подменяют worker-executable на простой shell-
  скрипт, реализующий тот же JSON-line протокол. Реальный MLX в xctest
  не запускается.
* **−** `loadModel` теперь медленнее на стоимость `posix_spawn` +
  ожидание `ready`. На M1 это ~50–100 мс — приемлемо для операции,
  которая уже занимает секунды на чтении весов.
* **−** Concurrent generate'ы между разными prompt'ами были бы заманчивы,
  но один worker = одна модель + последовательная генерация. Multiple
  worker'ов — отдельная задача, не для Mem-3.
* **−** Worker должен лежать рядом с демоном (`<exec_dir>/FroggyMLXWorker`)
  или в `config.mlxWorkerPath`. `packaging/` обновлено: codesign +
  notarytool теперь для **двух** бинарей.

## Альтернативы

* **Process pool с N worker'ами** — преждевременно. Сначала закроем
  «один работает» — потом расширим.
* **dlopen / dlclose динамической библиотеки MLX** — сэкономит fork/exec,
  но `dlclose` на macOS не гарантирует munmap страниц с весами.
* **`madvise(MADV_FREE)`** — Linux only.
