# Competitor analysis — Froggy vs ближайшие аналоги

* **Статус:** Living document
* **Дата:** 2026-05-09
* **Источники:** GitHub MCP (search + README), локальное чтение кода Froggy
* **Scope:** snapshot для ориентации при следующем дизайн-этапе; не маркетинг

## Зачем эта заметка существует

Уровень 1.5 (trust governance) ещё не закрыт — открывать Уровень 2 по ADR-0014
рано. Но **понять, где пространство не занято** — полезно до начала design'а,
а не после. Эта заметка фиксирует, что нашлось при обходе GitHub, чтобы не
перепроверять заново при старте каждого следующего слоя.

---

## Три значимых проекта

### 1. [owgit/memento-native](https://github.com/owgit/memento-native)

**Что делает:** local-first macOS screen memory — захват, OCR, семантический
поиск, timeline browsing. Swift 6 + ScreenCaptureKit + Vision + SQLite FTS5
+ on-device embeddings + H.264 видео-сегменты для timeline. Активный проект
(v2.1.3 на дату анализа). PolyForm NC лицензия.

**Ключевые отличия от Froggy:**

| Аспект | Memento | Froggy |
|---|---|---|
| LLM | Нет. OCR → поиск, без генерации | Есть. MLX inference в subprocess |
| Хранение | SQLite FTS5 + H.264 на диск | In-memory ring buffer, 30 снапшотов |
| Семантический поиск | On-device embeddings, работает | Нет |
| Memory management | Нет (LLM нет, давление не нужно) | Реактивный SIGSTOP + pageout |
| Redaction | Нет | AWS/GitHub/JWT/CC до записи на диск |
| URL-контекст | Да (Apple Events, браузеры) | Нет |
| Incognito auto-pause | Да | Нет |
| IPC / scriptability | Нет | Unix socket, JSON-line |
| RAM target | Не ограничен LLM | 8 GB — primary design audience |

**Где Froggy лучше:** вся memory-orchestration часть (SIGSTOP, pageout, subprocess
isolation), secret redaction, scriptability, LLM-инференс вместо search-only.

**Где Froggy хуже:** история исчезает при рестарте (Memento хранит месяцами);
нет URL-контекста; нет incognito-паузы; нет timeline.

**Важная граница:** POSITIONING явно говорит «Not a Rewind / Granola / Pi
alternative» и non-goal «Beating Memento on memory of past activity». Мы
не конкурируем. In-memory sliding window — дизайн-решение, не недоделка.

---

### 2. [signerlabs/Klee](https://github.com/signerlabs/Klee)

**Что делает:** native macOS AI agent, MLX, 100% local. Tool calling (file_read,
shell_exec, web_search), vision models (VLM), inline thinking, streaming.
Signed DMG, macOS 15+. Активный, полированный. MIT.

**Ключевые отличия от Froggy:**

| Аспект | Klee | Froggy |
|---|---|---|
| RAM target | **16 GB minimum** явно | 8 GB primary |
| Screen context | Нет | ScreenCaptureKit + OCR |
| Memory management | Нет (in-process MLX, unload косметический) | Реактивный, subprocess kill = real RAM return |
| Tool calling | Да (mlx-swift-lm ToolCall API) | Нет |
| VLM | Да | Нет (roadmap) |
| Model download | One-click HuggingFace | Ручной path |
| Scriptability | UI-only | Unix socket IPC |
| Audio/transcription | Нет | В разработке |

**Где Froggy лучше:** единственный в нише 8 GB; real RAM return при unload;
screen context awareness; scriptable.

**Где Froggy хуже:** нет tool calling; нет VLM; нет one-click model download;
нет Klee-эквивалента «agent who acts».

**Cherry-pick кандидат:** mlx-swift-lm ToolCall API — Klee показал что он
работает нативно. При design Уровня 2 — первый референс. Отдельный ID:
**COMPETITOR-KLEE-TOOLCALL** — смотреть `LLMService.swift` у Klee перед
design-doc'ом tool calling.

**Klee MLX оптимизации:** уже задокументированы в
[`docs/peer-research/klee-mlx-optimizations.md`](klee-mlx-optimizations.md)
(KLEE-A..KLEE-F).

---

### 3. [johnmai-dev/ChatMLX](https://github.com/johnmai-dev/ChatMLX)

**Что делает:** MLX chat app, multi-model, open source. Последний push — март
2025, стагнирует. Не подписан (xattr workaround), нет screen context, нет
memory management.

**Вывод:** не релевантен как референс. Зафиксировано для completeness —
не возвращаться.

---

## Что не делает никто (возможности Уровня 2+)

Эти пункты **не нарушают POSITIONING** — они идут из thesis'а («voice, VLM,
persona memory, and chat coexisting on 8 GB»), а не из конкуренции с Memento:

**1. Persistent screen context + LLM generation на 8 GB**
Memento хранит и ищет, но без LLM. Froggy генерирует с контекстом, но без
хранения. «Подведи итог того что я делал вчера» — никто не делает. Это
наш qualitative gap IF когда-нибудь откроем хранение (но см. POSITIONING
non-goal — не конкурировать с Rewind).

**2. Audio + screen контекст → LLM на 8 GB**
Klee не видит экран и не слышит. Memento не слышит и не генерирует. Froggy
строит оба канала. «Слышу что ты сейчас делаешь + вижу экран → ответ» —
уникально. Реализуется через meeting-transcription (аудио) + существующий
screen context.

**3. Tool calling над screen context**
LLM видит ошибку на экране → читает файл → предлагает фикс. Klee делает
tool calling, но слепой (не видит экран). Froggy видит экран, но не имеет
action loop. Соединение — qualitative новый класс.

**4. Memory management для VLM + LLM + audio на 8 GB**
Klee имеет VLM, но на 16 GB+ и без real RAM release. У нас subprocess
isolation (ADR-0008) решает это architectural — VLM worker убивается,
возвращает RAM. Это и есть thesis: «voice + VLM + chat coexisting on 8 GB».

---

## Quick wins из анализа (не нарушают POSITIONING, не Уровень 2)

Оба — маленькие LushaAccessor'ы, не архитектурные решения:

**QW-1: URL-accessor (Apple Events)**
Memento делает — Froggy нет. Новый `BrowserURLAccessor` в `LushaExperimental`:
Apple Events → активная вкладка Safari/Chrome/Arc → URL + title. Нужен
entitlement `com.apple.security.automation.apple-events`. 30 строк accessor +
`NSAppleEventsUsageDescription` в plist.

**QW-2: Incognito auto-pause**
Memento делает — Froggy нет. Privacy non-negotiable по THESIS. В `VisionActor`
перед каждым capture-циклом — Apple Events → `AXIsPrivate`. Если да —
пропускаем снапшот. Тот же entitlement что QW-1, логично один PR.

Оба — после снятия freeze на `Sources/**`.

---

## Явные non-goals (зафиксировать, не возвращаться)

Следуют из POSITIONING + thesis-compliance check 2026-05-09:

* **Persistent history / SQLite + FTS5** — POSITIONING: «Non-goal: Beating
  Rewind on memory of past activity». In-memory window — дизайн. Не трогать.
* **Signed DMG + auto-update как user-facing feature** — POSITIONING: «Not
  a consumer product. No installer, no auto-updates». Signing нужен для
  entitlements в prod; auto-update как feature — нет.
* **Semantic search (VecturaKit)** — тот же non-goal что persistent history.
* **Frame diff улучшение** — quantitative substrate, gravity trap. THESIS
  депrioritizes. Исключение: `VNGenerateImageFeaturePrintRequest` уже
  задокументирован в TODO как «рассмотреть при следующем касании FrameDigest».

---

## Источники и даты

* [signerlabs/Klee README](https://github.com/signerlabs/Klee/blob/main/README.md) — прочитан 2026-05-09
* [owgit/memento-native README](https://github.com/owgit/memento-native/blob/main/README.md) — прочитан 2026-05-09
* [johnmai-dev/ChatMLX README](https://github.com/johnmai-dev/ChatMLX/blob/main/README.md) — прочитан 2026-05-09
* GitHub MCP topic search: `mlx+swift`, `screencapturekit`, `apple-silicon+llm` — 2026-05-09
