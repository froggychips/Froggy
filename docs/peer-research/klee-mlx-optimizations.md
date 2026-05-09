# Klee — MLX-перф-оптимизации, кандидаты для FroggyMLXWorker

* **Источник:** [signerlabs/Klee](https://github.com/signerlabs/Klee). Основной файл —
  [`Klee/Service/LLMService.swift`](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)
  («Phase C optimizations applied based on oMLX engine_core.py analysis»),
  плюс [`Klee/Service/TokenizerPatcher.swift`](https://github.com/signerlabs/Klee/blob/main/Klee/Service/TokenizerPatcher.swift)
  для пункта KLEE-E. Ссылки — на `main` ветку, при чтении в будущем стоит
  свериться, что код не уехал и обоснования всё ещё актуальны.
* **Статус:** backlog. На дату создания файла действует freeze на правки `Sources/**`,
  применять — после снятия.
* **Дата:** 2026-05-09

## Зачем эта заметка существует

Klee — прямой архитектурный peer (Swift + mlx-swift на macOS), но **in-process**
MLX без supervisor/worker split. Архитектурно это хуже фрогги (нельзя убить
MLX без quit, нельзя вернуть unified memory). Но **внутри** генерации Klee
сделал серию точечных перф-настроек, которых у нас не проставлено. Ниже —
cherry-pick кандидаты с обоснованиями, чтобы при следующем заходе на
`FroggyMLXWorker` не перепроверять в Klee заново.

Разделено по пунктам с фиксированными ID (`KLEE-A`..`KLEE-E`) — чтобы можно
было ссылаться из коммитов / PR / issue.

---

## KLEE-A — Metal pipeline warmup после `loadModel`

Источник: `LLMService.swift` → `warmupMetalPipeline(_:)`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

После `loadModel` запускать фоновую 2-токенную генерацию:

```swift
let params = GenerateParameters(maxTokens: 2, temperature: 0.0, prefillStepSize: 512)
let stream = try await container.generate(input: warmupInput, parameters: params)
for await _ in stream {}  // дренируем чтобы Metal kernels успели скомпилиться
```

**Что делает:** компилирует Metal shader pipelines и греет memory allocators.
Без этого первый реальный user-запрос платит compile-time за shader cache.

**Применимость к фрогги:** `FroggyMLXWorker` сейчас этого не делает. После
`loadModel`-IPC первая генерация холоднее. У нас уже есть pre-build metallib
(ADR 0013) — это про сам факт наличия библиотеки, но pipeline cache всё равно
греется на первой генерации.

**Стоимость / выигрыш:** ~10–30 мс CPU + минимальный allocation, плата разовая
на жизнь worker'а. Выигрыш — детерминированный TTFT на первый user-запрос.

**Failure mode:** non-fatal. Если warmup упал — следующая генерация просто
будет холоднее, как сейчас. Логировать, не падать.

**Точка применения:** `FroggyMLXWorker/Entry.swift`, после успешного
`loadModel`, перед отправкой `ready` через IPC. Можно фоновым `Task`'ом —
тогда `ready` улетает раньше, а warmup догоняется в фоне.

---

## KLEE-B — `Memory.cacheLimit` под систему

Источник: `LLMService.swift` → `configureGPUMemoryLimit()`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

```swift
if let recommended = GPU.maxRecommendedWorkingSetBytes() {
    Memory.cacheLimit = Int(Double(recommended) * 0.75)
}
```

**Что делает:** ограничивает MLX memory cache 75% от
`GPU.maxRecommendedWorkingSetBytes()`. Без этого MLX greedy с unified memory.

**Почему критично именно у нас:** Vortex-демон сам мониторит memory pressure
(`MemoryPressureMonitor`, `FreezeStatsStore`). Если worker без лимита съел
всё — supervisor поймёт через pressure → freeze, но это patch over root
cause. Лучше ограничить заранее.

**Применимость:** `FroggyMLXWorker/Entry.swift`, сразу после `import MLX`,
до первого `loadModel`. Можно сделать tunable через CLI-флаг `--mlx-cache-mb`
аналогично `--kv-bits` (см. ADR 0009) или env-переменную. Дефолт 75% —
sane, но в случае старых 8 GB-маков может оказаться тесно — стоит померять.

**Связь с другими ADR:** не противоречит ADR 0008 (subprocess isolation —
worker всё равно умрёт по unloadModel и unified memory вернётся ядру);
дополняет ADR 0009 (kvBits ограничивает KV-cache, cacheLimit — общий MLX-кеш).

---

## KLEE-C — `GenerateParameters`: prefillStepSize + sampler nuances

Источник: `LLMService.swift` → `makeGenerateParameters(kvBits:)`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

Из комментария Klee к `makeGenerateParameters`:

```
- prefillStepSize 512: matches oMLX scheduler default, processes prompt in chunks
- temperature 0.6: uses CategoricalSampler (efficient)
- topP 1.0 (default): avoids TopPSampler overhead (softmax+cumsum+sort per token).
                       CategoricalSampler is already selected by temperature > 0 alone.
- repetitionPenalty nil: no LogitProcessor created → zero per-token processing overhead
```

Два неочевидных нюанса mlx-swift-lm:

1. **`topP: 1.0` (передан явно) ≠ `topP: nil`.** Если выставить `1.0`,
   вокруг каждого токена крутится `softmax + cumsum + sort`. Для top-p
   sampling'а 1.0 == «без эффекта», но overhead остаётся. **Передавать
   `nil` / не указывать**, если top-p не нужен.
2. **`repetitionPenalty: 0` или дефолтное число тоже плохо.** Любой
   не-nil создаёт `LogitProcessor`, прицеплённый к decode loop'у. nil →
   zero overhead.

**Что проверить в фрогги:** все места, где собирается `GenerateParameters`.
Конкретно:
- `FroggyMLXWorker/Entry.swift::handleGenerate` (или где сейчас сборка
  параметров живёт после ADR 0009).
- IPC-входы `MLXWorkerCommand` — если `topP`/`repetitionPenalty` пробрасываются
  с дефолтом «1.0»/«0», заменить на optional с дефолтом nil.

`prefillStepSize: 512` сейчас, скорее всего, не выставлен — если так, это
просто добавление одного поля в `GenerateParameters`.

---

## KLEE-D — `ModelConfiguration(directory:)` для уже-кешированных моделей

Источник: `LLMService.swift` → `loadModel(id:)` (блок выбора `configuration`,
[blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

```swift
let isCachedLocally = FileManager.default.fileExists(atPath: localURL.path)
let configuration = isCachedLocally
    ? ModelConfiguration(directory: localURL)
    : ModelConfiguration(id: id)
```

**Klee комментарий:** *Hub normally fetches remote hashes even for cached models.*

Иначе говоря: `ModelConfiguration(id:)` дёргает HuggingFace Hub для проверки
ETag даже когда файлы лежат локально. Это:
- лишний network roundtrip на каждый load,
- падение при отсутствии интернета (даже если модель уже скачана),
- лишнее ожидание при медленной сети.

**Применимость к фрогги:** если когда-то всплывал баг «worker не загружает
уже скачанную модель когда нет интернета» — это, скорее всего, оно. Также
актуально для CI: `make full` в bench/ под ipv6-only, корпоративный proxy,
DNS-проблемы — любые сценарии когда HF hub flaky.

**Точка применения:** место где worker резолвит модельный путь. Нужно
посмотреть как фрогги сейчас передаёт модель в worker — через `--model-path`
с локальным путём или через HF id. Если уже через локальный путь — KLEE-D
неприменимо.

---

## KLEE-E — TokenizerPatcher: chat_template missing fallback

Источник: [`Klee/Service/TokenizerPatcher.swift`](https://github.com/signerlabs/Klee/blob/main/Klee/Service/TokenizerPatcher.swift),
функция `patchTokenizerConfigIfNeeded(modelId:localURL:)`.

> Some mlx-community models omit chat_template, causing inference to fail.

Klee на load проверяет `tokenizer_config.json` загруженной модели; если в
нём нет поля `chat_template`:

1. Пытается выкачать оригинальный `tokenizer_config.json` из HF (возможно,
   там template есть, а в mlx-community quantize-версии его потеряли).
2. Фоллбачит на bundled `QwenChatTemplate` / семейство.
3. Записывает патченый JSON обратно на диск.

**Failure mode:** silent log, не блокирует main download flow.

**Применимость к фрогги:** реальный road bump на mlx-community
quantized моделях — встречается, например, на некоторых `Qwen3.5-*-4bit`
дистрибутивах. Если у пользователей фрогги когда-то всплывал крах
worker'а на первой генерации после успешной загрузки модели — посмотреть
`tokenizer_config.json` в model dir, скорее всего там нет `chat_template`.

**Стоимость:** ~60 строк Swift + bundled template-ресурсы. Klee тащит
один шаблон (`QwenChatTemplate`), мы можем брать только под те семейства,
которые реально используем.

---

## KLEE-F (бонус) — точные метрики через `GenerateCompletionInfo`

Источник: `LLMService.swift`, поля `lastPrefillTimeMs` /
`lastDecodeTokensPerSec` / `lastTotalTokens` / `lastTotalTimeMs`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).
Сам `GenerateCompletionInfo` приходит из mlx-swift-lm.

mlx-swift-lm встроенно отдаёт `GenerateCompletionInfo` с раздельными:

* `lastPrefillTimeMs` — TTFT / prefill, миллисекунды
* `lastDecodeTokensPerSec` — decode-only TPS, **без** prefill bias
* `lastTotalTokens`, `lastTotalTimeMs`

**Применимость:** если в `bench/run.sh` сейчас считаем
`tokens_per_sec = total_tokens / total_time` — это смешивает prefill и
decode. Для коротких prompt'ов ок, для длинных — TTFT доминирует и метрика
ползёт. Использовать встроенное API → честные раздельные числа в
`baseline.json`.

**Точка применения:** где-то рядом с ADR 0011 «code-first-design-second
для Уровня 2» — там как раз про validation gate через bench. Если
baseline пишется до этого изменения, можно либо переписать его с честными
метриками, либо отдельной графой добавить.

---

## Что из Klee сознательно НЕ нести

* **In-process архитектура** — у нас лучше через subprocess (ADR 0008).
* **HuggingFace mirror через env (`HF_ENDPOINT`)** — это для китайского
  CDN, не наш сценарий.
* **IntentRouter / shell_exec / web_search** — Klee — chat-агент, у нас
  process supervisor; разные домены.
* **CI / тесты Klee** — у Klee их **нет вообще** (нет workflows, нет
  test target'ов). Мы впереди.

---

## ml-aim, mlx-tune — почему не релевантны

Изучены вместе с Klee, оставляю одной строкой каждый чтобы не возвращаться
зря.

* **[apple/ml-aim](https://github.com/apple/ml-aim)** — vision encoder
  pretraining (AIMv1/v2, CVPR 2025 / ICML 2024). Research-код Python,
  не infra. К фрогги ноль applicability — мы не делаем vision pretraining.
* **[ARahim3/mlx-tune](https://github.com/ARahim3/mlx-tune)** — Python
  fine-tuning toolkit на MLX (SFT/DPO/GRPO/Vision/TTS/STT/OCR). Training,
  не inference + process management. Может стать интересно, если в
  каком-то отдалённом roadmap-году захочется on-device LoRA для
  Vortex-policy под привычки пользователя — но это годы, не сейчас.

---

## Когда применять

После явного снятия freeze'а на `Sources/**`. Делать одним PR на все
пять пунктов **не надо** — каждый имеет независимую ценность и независимую
зону тестирования. Минимальное разбиение:

1. **PR 1: KLEE-A + KLEE-B + KLEE-C** — все на `FroggyMLXWorker/Entry.swift`,
   близкие по теме (init/teardown/params). Один регресс-тест бенчем.
2. **PR 2: KLEE-D** — отдельно, потому что меняет model loading flow,
   нужен сценарный тест (offline/cached vs online/fresh).
3. **PR 3: KLEE-E** — отдельный PR с TokenizerPatcher + bundled templates;
   ресурсная история (см. ADR 0013 про bundled ресурсы и mlx-swift
   search-paths) и нужно отдельно проверить на конкретных
   mlx-community моделях.
4. **PR 4 (опц): KLEE-F** — переход на `GenerateCompletionInfo`. Затронет
   `bench/baseline.json` — нужно бить вместе с rebaseline'ом и согласовать
   с ADR 0011.
